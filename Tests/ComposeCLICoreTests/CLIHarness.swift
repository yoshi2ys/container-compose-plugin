import ContainerEngine
import EngineTestSupport
import Foundation

@testable import ComposeCLICore

/// Collects the two output streams of one `ComposeCLI.run`.
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    var stdout: String { lock.withLock { out } }
    var stderr: String { lock.withLock { err } }

    func appendOut(_ text: String) { lock.withLock { out += text } }
    func appendErr(_ text: String) { lock.withLock { err += text } }
}

struct CLIRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let operations: [String]
    /// Full argv of every `container run`, for asserting translated values.
    let runInvocations: [[String]]
}

/// Runs the CLI against an in-memory filesystem (`files`: path → contents) and a
/// recording engine.
func runCLI(
    _ arguments: [String],
    files: [String: String] = [:],
    directories: Set<String> = [],
    currentDirectory: String = "/work",
    engine: FakeEngine = FakeEngine(),
    environment: [String: String] = [:]
) async -> CLIRun {
    let sink = OutputSink()
    let context = CLIContext(
        arguments: arguments,
        currentDirectory: currentDirectory,
        write: { sink.appendOut($0) },
        writeError: { sink.appendErr($0) },
        pathKind: { path in
            if files[path] != nil { return .file }
            if directories.contains(path) { return .directory }
            return .missing
        },
        readFile: { path in
            guard let contents = files[path] else { throw CLIError("unreadable: \(path)") }
            return contents
        },
        makeEngine: { engine },
        environment: environment
    )
    let code = await ComposeCLI.run(context)
    return CLIRun(
        exitCode: code, stdout: sink.stdout, stderr: sink.stderr,
        operations: await engine.operations, runInvocations: await engine.runInvocations)
}
