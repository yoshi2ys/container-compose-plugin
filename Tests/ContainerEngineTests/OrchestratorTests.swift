import Testing
import ComposeModel
@testable import ContainerEngine

/// Records the sequence of engine operations so tests can assert ordering.
actor MockEngine: ContainerEngine {
    var operations: [String] = []
    var running = true

    func setRunning(_ value: Bool) { running = value }

    func systemRunning() async throws -> Bool { running }

    func run(argv: [String]) async throws -> String {
        operations.append("run:\(value(after: "--name", in: argv) ?? "?")")
        return "id"
    }
    func build(argv: [String]) async throws {
        operations.append("build:\(value(after: "-t", in: argv) ?? "?")")
    }
    func createNetwork(argv: [String]) async throws {
        operations.append("net:\(argv.count > 2 ? argv[2] : "?")")
    }
    func createVolume(argv: [String]) async throws {
        operations.append("vol:\(argv.count > 2 ? argv[2] : "?")")
    }
    func stop(name: String, timeout: Int?) async throws { operations.append("stop:\(name)") }
    func remove(name: String, force: Bool) async throws { operations.append("rm:\(name)") }
    func forward(argv: [String]) async throws -> Int32 {
        operations.append("forward:\(argv.joined(separator: " "))")
        return 0
    }

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }
}

@Suite("Orchestrator")
struct OrchestratorTests {

    private func project(_ yaml: String) throws -> ComposeProject {
        try ComposeParser.parse(yaml, projectNameFallback: "p").project
    }

    @Test("up starts services in dependency-wave order")
    func upOrder() async throws {
        let proj = try project("""
        name: demo
        services:
          base:
            image: x
          left:
            image: x
            depends_on: [base]
          right:
            image: x
            depends_on: [base]
          top:
            image: x
            depends_on: [left, right]
        """)
        let mock = MockEngine()
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let ops = await mock.operations
        #expect(ops == ["run:demo-base", "run:demo-left", "run:demo-right", "run:demo-top"])
    }

    @Test("up creates prerequisites before starting services")
    func upPrerequisites() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: postgres
            networks: [backend]
            volumes: [dbdata:/data]
        networks:
          backend:
        volumes:
          dbdata:
        """)
        let mock = MockEngine()
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let ops = await mock.operations
        #expect(ops == ["net:backend", "vol:dbdata", "run:demo-db"])
    }

    @Test("down stops and removes in reverse order")
    func downOrder() async throws {
        let proj = try project("""
        name: demo
        services:
          base:
            image: x
          top:
            image: x
            depends_on: [base]
        """)
        let mock = MockEngine()
        try await ComposeOrchestrator(engine: mock).down(project: proj)
        let ops = await mock.operations
        #expect(ops == ["stop:demo-top", "rm:demo-top", "stop:demo-base", "rm:demo-base"])
    }

    @Test("up refuses when the system is not running, touching nothing")
    func upSystemNotRunning() async throws {
        let proj = try project("services:\n  a:\n    image: x\n")
        let mock = MockEngine()
        await mock.setRunning(false)
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).up(project: proj)
        }
        let ops = await mock.operations
        #expect(ops.isEmpty)
    }

    @Test("up validates before mutating: a blocking service starts nothing")
    func upBlockingStartsNothing() async throws {
        let proj = try project("""
        name: demo
        services:
          good:
            image: x
          bad:
            environment:
              X: "1"
        """)
        let mock = MockEngine()
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).up(project: proj)
        }
        let ops = await mock.operations
        #expect(ops.isEmpty)
    }
}
