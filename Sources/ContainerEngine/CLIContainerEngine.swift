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
        // `container system status` exits 0 even when the apiserver is down (it prints
        // "... is not running ..."), so the status text decides; otherwise trust the exit.
        try await statusIsRunning(["system", "status"]) { result, _ in result.exitCode == 0 }
    }

    public func builderRunning() async throws -> Bool {
        // `container builder status` prints "builder is not running" when down, or a
        // table row whose STATE is "running" when up — the text is authoritative.
        try await statusIsRunning(["builder", "status"]) { _, text in text.contains("running") }
    }

    public func startBuilder() async throws {
        // Inherit stdio so the first-run builder-image pull streams to the terminal.
        let code = try await runner.runInheritingIO(executable, prefix + ["builder", "start"])
        guard code == 0 else {
            throw EngineError(argv: ["builder", "start"], exitCode: code, stderr: "")
        }
    }

    public func hostGateway() async throws -> String? {
        // The default network's IPv4 gateway is the host's address from inside containers.
        let result = try await capture(["network", "inspect", "default"])
        guard let gateway = firstStatus(in: result)?["ipv4Gateway"] as? String else { return nil }
        // May be "192.168.64.1" or "192.168.64.1/24" — keep just the address.
        return gateway.split(separator: "/").first.map(String.init)
    }

    public func run(argv: [String]) async throws -> String {
        let result = try await capture(argv)
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func build(argv: [String]) async throws {
        // Inherit stdio so build progress streams live to the terminal — this also
        // keeps verbose output off the captured path (avoids any pipe-buffer stall).
        // Force `--progress plain` here (an IO concern): it streams cleanly whether or
        // not stdout is a TTY. `argv` always starts with the `build` subcommand.
        var full = argv
        full.insert(contentsOf: ["--progress", "plain"], at: 1)
        let code = try await runner.runInheritingIO(executable, prefix + full)
        // Report the command we actually ran (with `--progress plain`) so it reproduces.
        guard code == 0 else { throw EngineError(argv: full, exitCode: code, stderr: "") }
    }
    public func createNetwork(argv: [String]) async throws { _ = try await capture(argv) }
    public func createVolume(argv: [String]) async throws { _ = try await capture(argv) }

    public func exec(name: String, argv: [String]) async throws -> Int32 {
        try await runner.run(executable, prefix + ["exec", name] + argv).exitCode
    }

    public func state(name: String) async throws -> ContainerState {
        // Use `run` (not `capture`): a missing/stopped container must not throw — it
        // simply reads as "not running". `container inspect` omits the exit code.
        let result = try await runner.run(executable, prefix + ["inspect", name])
        guard let status = firstStatus(in: result), let state = status["state"] as? String
        else { return ContainerState(running: false) }
        return ContainerState(
            running: state.lowercased() == "running",
            exitCode: (status["exitCode"] as? Int).map(Int32.init))
    }

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

    /// Shared "is it up?" check for `system`/`builder status`: the CLI prints
    /// "... not running ..." even on a zero exit, so a negative phrase always wins;
    /// otherwise the per-call `positive` predicate decides (exit code or status text).
    private func statusIsRunning(
        _ argv: [String], positive: (ProcessResult, String) -> Bool
    ) async throws -> Bool {
        let result = try await runner.run(executable, prefix + argv)
        let text = (result.stdoutString + result.stderrString).lowercased()
        if text.contains("not running") || text.contains("not registered") { return false }
        return positive(result, text)
    }

    /// The first element's `status` object from a `container … inspect` JSON array.
    private func firstStatus(in result: ProcessResult) -> [String: Any]? {
        guard let data = result.stdoutString.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.first?["status"] as? [String: Any]
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
