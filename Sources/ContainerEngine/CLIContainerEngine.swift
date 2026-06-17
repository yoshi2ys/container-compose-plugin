import Foundation

/// `ContainerEngine` implemented by shelling out to the `container` CLI.
///
/// Invokes via `/usr/bin/env container …` so it follows `PATH` regardless of
/// install location. An `actor` to serialize process spawning.
public actor CLIContainerEngine: ContainerEngine {
    private let runner: ProcessRunner
    private let executable: String
    private let prefix: [String]

    /// - Parameters:
    ///   - runner: process seam (defaults to the real subprocess runner).
    ///   - executable / prefix: how to invoke `container`. Default runs
    ///     `/usr/bin/env container …`; pass `executable: "/usr/local/bin/container", prefix: []`
    ///     to call the binary directly.
    public init(
        runner: ProcessRunner = SubprocessRunner(),
        executable: String = "/usr/bin/env",
        prefix: [String] = ["container"]
    ) {
        self.runner = runner
        self.executable = executable
        self.prefix = prefix
    }

    public func systemRunning() async throws -> Bool {
        // `container system status` exits 0 even when the apiserver is down (it just
        // prints "... is not running ..."), so the status text is authoritative.
        let result = try await runner.run(executable, prefix + ["system", "status"])
        let combined = (result.stdoutString + result.stderrString).lowercased()
        if combined.contains("not running") || combined.contains("not registered") { return false }
        return result.exitCode == 0
    }

    public func run(argv: [String]) async throws -> String {
        let result = try await capture(argv)
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func build(argv: [String]) async throws {
        // Inherit stdio so build progress streams live to the terminal — this also
        // keeps verbose output off the captured path (avoids any pipe-buffer stall).
        let code = try await runner.runInheritingIO(executable, prefix + argv)
        guard code == 0 else { throw EngineError(argv: argv, exitCode: code, stderr: "") }
    }
    public func createNetwork(argv: [String]) async throws { _ = try await capture(argv) }
    public func createVolume(argv: [String]) async throws { _ = try await capture(argv) }

    public func stop(name: String, timeout: Int?) async throws {
        var argv = ["stop"]
        if let timeout { argv += ["-t", "\(timeout)"] }
        argv += [name]
        _ = try await capture(argv)
    }

    public func remove(name: String, force: Bool) async throws {
        var argv = ["delete"]
        if force { argv += ["-f"] }
        argv += [name]
        _ = try await capture(argv)
    }

    public func forward(argv: [String]) async throws -> Int32 {
        try await runner.runInheritingIO(executable, prefix + argv)
    }

    /// Run a `container` subcommand and throw `EngineError` on non-zero exit.
    private func capture(_ argv: [String]) async throws -> ProcessResult {
        let result = try await runner.run(executable, prefix + argv)
        guard result.exitCode == 0 else {
            throw EngineError(
                argv: argv, exitCode: result.exitCode,
                stderr: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}
