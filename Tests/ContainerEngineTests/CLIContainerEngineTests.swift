import Testing
import Foundation
@testable import ContainerEngine

/// Records invocations and returns a canned result, so we can assert the exact
/// argv the engine hands to the process layer without spawning anything.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    nonisolated(unsafe) var calls: [(executable: String, arguments: [String])] = []
    nonisolated(unsafe) var result = ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0)
    nonisolated(unsafe) var inheritExit: Int32 = 0

    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        calls.append((executable, arguments))
        return result
    }
    func runInheritingIO(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        calls.append((executable, arguments))
        return inheritExit
    }
}

@Suite("CLIContainerEngine")
struct CLIContainerEngineTests {

    @Test("run invokes `env container <argv>` and returns trimmed stdout")
    func runInvokesContainer() async throws {
        let runner = FakeRunner()
        runner.result = ProcessResult(stdout: Data("abc123\n".utf8), stderr: Data(), exitCode: 0)
        let engine = CLIContainerEngine(runner: runner)

        let id = try await engine.run(argv: ["run", "-d", "--name", "demo-web", "nginx"])
        #expect(id == "abc123")
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == "/usr/bin/env")
        #expect(runner.calls[0].arguments == ["container", "run", "-d", "--name", "demo-web", "nginx"])
    }

    @Test("captured command non-zero exit throws EngineError with argv and stderr")
    func nonZeroThrows() async throws {
        let runner = FakeRunner()
        runner.result = ProcessResult(stdout: Data(), stderr: Data("boom\n".utf8), exitCode: 2)
        let engine = CLIContainerEngine(runner: runner)

        await #expect(throws: EngineError(argv: ["run", "-d", "x"], exitCode: 2, stderr: "boom")) {
            _ = try await engine.run(argv: ["run", "-d", "x"])
        }
    }

    @Test("build streams via inherited IO and throws on non-zero exit")
    func buildInheritsIOAndThrows() async throws {
        let runner = FakeRunner()
        runner.inheritExit = 3
        let engine = CLIContainerEngine(runner: runner)

        // the engine forces `--progress plain`, and the error reports the command it ran.
        await #expect(throws: EngineError(
            argv: ["build", "--progress", "plain", "-t", "t", "."], exitCode: 3, stderr: "")) {
            try await engine.build(argv: ["build", "-t", "t", "."])
        }
        #expect(runner.calls[0].arguments == ["container", "build", "--progress", "plain", "-t", "t", "."])
    }

    @Test("systemRunning reflects exit code")
    func systemRunning() async throws {
        let runner = FakeRunner()
        let engine = CLIContainerEngine(runner: runner)

        runner.result = ProcessResult(stdout: Data("apiserver is running".utf8), stderr: Data(), exitCode: 0)
        #expect(try await engine.systemRunning() == true)

        // R1: status exits 0 even when down, so the text must override the exit code.
        runner.result = ProcessResult(stdout: Data("apiserver is not running and not registered".utf8), stderr: Data(), exitCode: 0)
        #expect(try await engine.systemRunning() == false)

        runner.result = ProcessResult(stdout: Data(), stderr: Data("apiserver is not running".utf8), exitCode: 1)
        #expect(try await engine.systemRunning() == false)
    }

    @Test("builderRunning reads the status text, not the exit code")
    func builderRunning() async throws {
        let runner = FakeRunner()
        let engine = CLIContainerEngine(runner: runner)

        runner.result = ProcessResult(stdout: Data("ID        STATE\nbuildkit  running".utf8), stderr: Data(), exitCode: 0)
        #expect(try await engine.builderRunning() == true)

        runner.result = ProcessResult(stdout: Data("builder is not running".utf8), stderr: Data(), exitCode: 0)
        #expect(try await engine.builderRunning() == false)
    }

    @Test("startBuilder runs `builder start` via inherited IO and throws on non-zero")
    func startBuilder() async throws {
        let runner = FakeRunner()
        let engine = CLIContainerEngine(runner: runner)
        try await engine.startBuilder()
        #expect(runner.calls[0].arguments == ["container", "builder", "start"])

        runner.inheritExit = 1
        await #expect(throws: EngineError.self) { try await engine.startBuilder() }
    }

    @Test("hostGateway extracts ipv4Gateway from the default-network inspect JSON (strips CIDR)")
    func hostGateway() async throws {
        let runner = FakeRunner()
        let json = #"[{"id":"default","status":{"ipv4Gateway":"192.168.64.1","ipv4Subnet":"192.168.64.0/24"}}]"#
        runner.result = ProcessResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 0)
        let engine = CLIContainerEngine(runner: runner)

        #expect(try await engine.hostGateway() == "192.168.64.1")
        #expect(runner.calls[0].arguments == ["container", "network", "inspect", "default"])
    }

    @Test("stop and remove build the expected argv")
    func stopAndRemove() async throws {
        let runner = FakeRunner()
        let engine = CLIContainerEngine(runner: runner)

        try await engine.stop(name: "demo-web", timeout: 3)
        try await engine.remove(name: "demo-web", force: true)
        #expect(runner.calls[0].arguments == ["container", "stop", "-t", "3", "demo-web"])
        #expect(runner.calls[1].arguments == ["container", "delete", "-f", "demo-web"])
    }

    @Test("forward passes through to inherited-IO and returns its exit code")
    func forward() async throws {
        let runner = FakeRunner()
        runner.inheritExit = 7
        let engine = CLIContainerEngine(runner: runner)

        let code = try await engine.forward(argv: ["list", "--all"])
        #expect(code == 7)
        #expect(runner.calls[0].arguments == ["container", "list", "--all"])
    }
}
