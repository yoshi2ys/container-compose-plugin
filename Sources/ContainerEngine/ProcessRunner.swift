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
    /// Run to completion, handing each output line to `onLine` as it arrives.
    ///
    /// Separate from `run` because a followed log lives as long as the stack:
    /// buffering it to completion would print nothing until the process ended.
    /// Cancelling the surrounding task terminates the process.
    func stream(
        _ executable: String, _ arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

/// Pairs the two things that have to happen before a stream is done — the pipe
/// reaching EOF and the process exiting — and resumes the waiter exactly once.
private final class StreamCompletion: @unchecked Sendable {
    enum Event {
        case endOfFile
        case exited(Int32)
    }

    private let lock = NSLock()
    private var sawEndOfFile = false
    private var status: Int32?
    private var resume: ((Int32) -> Void)?
    private var resumed = false

    func onReady(_ resume: @escaping (Int32) -> Void) {
        let ready: Int32? = lock.withLock {
            self.resume = resume
            return readyStatusLocked()
        }
        if let ready { deliver(ready) }
    }

    func finish(_ event: Event) {
        let ready: Int32? = lock.withLock {
            switch event {
            case .endOfFile: sawEndOfFile = true
            case .exited(let code): status = code
            }
            return readyStatusLocked()
        }
        if let ready { deliver(ready) }
    }

    /// Call with the lock held.
    private func readyStatusLocked() -> Int32? {
        guard sawEndOfFile, let status, resume != nil, !resumed else { return nil }
        resumed = true
        return status
    }

    private func deliver(_ status: Int32) {
        let resume = lock.withLock { self.resume }
        resume?(status)
    }
}

/// Splits a byte stream into lines. `Process` hands over arbitrary chunks, so a
/// line can arrive in pieces or several can arrive at once.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var complete: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                complete.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending = pending[pending.index(after: newline)...]
            }
            return complete
        }
        for line in lines { onLine(line) }
    }

    /// Emits whatever is left when the process ends without a trailing newline.
    func flush() {
        let rest: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let text = String(decoding: pending, as: UTF8.self)
            pending = Data()
            return text
        }
        if let rest { onLine(rest) }
    }
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

    public func stream(
        _ executable: String, _ arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let process = makeProcess(executable, arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LineBuffer(onLine: onLine)
        // Resumed once, when the pipe has reached EOF *and* the process has exited.
        // Waiting on both is what guarantees the last lines are delivered; reading the
        // remainder from the termination handler instead would block there until every
        // holder of the write end closed it, with no way out but cancellation.
        let completion = StreamCompletion()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                buffer.flush()
                completion.finish(.endOfFile)
                return
            }
            buffer.append(data)
        }

        try process.run()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.onReady { status in continuation.resume(returning: status) }
                process.terminationHandler = { finished in
                    completion.finish(.exited(finished.terminationStatus))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private func makeProcess(_ executable: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        return process
    }
}
