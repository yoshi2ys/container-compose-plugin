import Foundation

public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// The lowest-level seam: spawn a process. Faked in tests so the engine and
/// orchestrator are unit-testable without ever touching the real `container` CLI.
public protocol ProcessRunner: Sendable {
    /// Run to completion, capturing stdout/stderr.
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult
    /// Run with the parent's stdout/stderr inherited (for `ps`/`logs` passthrough),
    /// returning the exit code.
    func runInheritingIO(_ executable: String, _ arguments: [String]) async throws -> Int32
}

/// Real `Foundation.Process`-backed runner. Stateless (hence `Sendable`); each call
/// owns its `Process` locally, so nothing crosses a concurrency boundary.
public struct SubprocessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let process = makeProcess(executable, arguments)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Only small-output commands reach this path (run id, stop, delete, network/
        // volume create, system status); verbose commands — build, ps, logs — use
        // runInheritingIO. So neither pipe buffer can fill, and sequential drain is safe.
        let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return ProcessResult(stdout: outData, stderr: errData, exitCode: process.terminationStatus)
    }

    public func runInheritingIO(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        let process = makeProcess(executable, arguments)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makeProcess(_ executable: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        return process
    }
}
