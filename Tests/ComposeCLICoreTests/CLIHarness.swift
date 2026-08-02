import ComposeTranslate
import ContainerEngine
import Foundation

@testable import ComposeCLICore

/// Records engine calls and returns canned results, so CLI tests exercise the
/// whole argv → orchestrator path without spawning `container`.
actor RecordingEngine: ContainerEngine {
    var operations: [String] = []
    private var running: Bool
    private var builderUp: Bool
    private let forwardExit: Int32

    init(running: Bool = true, builderUp: Bool = true, forwardExit: Int32 = 0) {
        self.running = running
        self.builderUp = builderUp
        self.forwardExit = forwardExit
    }

    func systemRunning() async throws -> Bool { running }
    func builderRunning() async throws -> Bool { builderUp }
    func startBuilder() async throws { operations.append("builderstart") }
    func hostGateway() async throws -> String? { nil }
    func run(argv: [String]) async throws -> String {
        operations.append("run:\(value(after: "--name", in: argv) ?? "?")")
        return "id"
    }
    func build(argv: [String]) async throws {
        operations.append("build:\(value(after: "-t", in: argv) ?? "?")")
    }
    func createNetwork(argv: [String]) async throws { operations.append("net") }
    func createVolume(argv: [String]) async throws { operations.append("vol") }
    func exec(name: String, argv: [String]) async throws -> Int32 { 0 }
    func state(name: String) async throws -> ContainerState { ContainerState(running: false) }
    func stop(name: String, timeout: Int?) async throws { operations.append("stop:\(name)") }
    func remove(name: String, force: Bool) async throws { operations.append("rm:\(name)") }
    func forward(argv: [String]) async throws -> Int32 {
        operations.append("forward:\(argv.joined(separator: " "))")
        return forwardExit
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }
}

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
}

/// Runs the CLI against an in-memory filesystem (`files`: path → contents) and a
/// recording engine.
func runCLI(
    _ arguments: [String],
    files: [String: String] = [:],
    directories: Set<String> = [],
    currentDirectory: String = "/work",
    engine: RecordingEngine = RecordingEngine()
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
        makeEngine: { engine }
    )
    let code = await ComposeCLI.run(context)
    return CLIRun(
        exitCode: code, stdout: sink.stdout, stderr: sink.stderr,
        operations: await engine.operations)
}
