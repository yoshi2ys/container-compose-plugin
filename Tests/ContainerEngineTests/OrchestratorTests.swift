import Testing
import ComposeModel
@testable import ContainerEngine

/// Records the sequence of engine operations so tests can assert ordering.
actor MockEngine: ContainerEngine {
    var operations: [String] = []
    var running = true
    var builderUp = true

    func setRunning(_ value: Bool) { running = value }
    func setBuilderUp(_ value: Bool) { builderUp = value }

    /// Consumed per `exec`/`state` call; empty falls back to success/stopped.
    var execResults: [Int32] = []
    var states: [ContainerState] = []
    func setExecResults(_ value: [Int32]) { execResults = value }
    func setStates(_ value: [ContainerState]) { states = value }

    func systemRunning() async throws -> Bool { running }
    func builderRunning() async throws -> Bool { builderUp }
    func startBuilder() async throws { operations.append("builderstart") }
    func hostGateway() async throws -> String? { nil }

    func exec(name: String, argv: [String]) async throws -> Int32 {
        operations.append("exec:\(name)")
        return execResults.isEmpty ? 0 : execResults.removeFirst()
    }
    func state(name: String) async throws -> ContainerState {
        operations.append("state:\(name)")
        return states.isEmpty ? ContainerState(running: false) : states.removeFirst()
    }

    func run(argv: [String]) async throws -> String {
        operations.append("run:\(value(after: "--name", in: argv) ?? "?")")
        return "id"
    }
    /// Full argv of every `build` call, for asserting flags like `--no-cache`.
    var buildInvocations: [[String]] = []
    func build(argv: [String]) async throws {
        buildInvocations.append(argv)
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
        // each service is recreated: remove-then-run, in dependency-wave order.
        #expect(ops == [
            "rm:demo-base", "run:demo-base",
            "rm:demo-left", "run:demo-left",
            "rm:demo-right", "run:demo-right",
            "rm:demo-top", "run:demo-top",
        ])
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
        #expect(ops == ["net:backend", "vol:dbdata", "rm:demo-db", "run:demo-db"])
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

    @Test("build builds every service that declares a build section")
    func buildAll() async throws {
        let proj = try project("""
        name: demo
        services:
          api:
            build:
              context: ./api
          web:
            build:
              context: ./web
          cache:
            image: redis
        """)
        let mock = MockEngine()
        let built = try await ComposeOrchestrator(engine: mock).build(project: proj)
        let ops = await mock.operations
        #expect(Set(built) == ["api", "web"])
        #expect(ops.contains("build:demo-api:compose"))
        #expect(ops.contains("build:demo-web:compose"))
        #expect(!ops.contains("build:demo-cache:compose"))  // image-only service is skipped
    }

    @Test("build restricts to the named services")
    func buildNamed() async throws {
        let proj = try project("""
        name: demo
        services:
          api:
            build:
              context: ./api
          web:
            build:
              context: ./web
        """)
        let mock = MockEngine()
        let built = try await ComposeOrchestrator(engine: mock).build(project: proj, services: ["api"])
        let ops = await mock.operations
        #expect(built == ["api"])
        #expect(ops.contains("build:demo-api:compose"))
        #expect(!ops.contains("build:demo-web:compose"))
    }

    @Test("build starts the builder when it is down")
    func buildStartsBuilder() async throws {
        let proj = try project("name: demo\nservices:\n  api:\n    build:\n      context: ./api\n")
        let mock = MockEngine()
        await mock.setBuilderUp(false)
        try await ComposeOrchestrator(engine: mock).build(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("builderstart"))
        #expect(ops.contains("build:demo-api:compose"))
    }

    @Test("build --no-cache passes the flag to every build")
    func buildNoCache() async throws {
        let proj = try project("name: demo\nservices:\n  api:\n    build:\n      context: ./api\n")
        let mock = MockEngine()
        try await ComposeOrchestrator(engine: mock).build(project: proj, noCache: true)
        let invocations = await mock.buildInvocations
        #expect(!invocations.isEmpty)
        #expect(invocations.allSatisfy { $0.contains("--no-cache") })
    }

    @Test("build with no buildable services does nothing and leaves the builder alone")
    func buildNothing() async throws {
        let proj = try project("name: demo\nservices:\n  a:\n    image: x\n")
        let mock = MockEngine()
        await mock.setBuilderUp(false)
        let built = try await ComposeOrchestrator(engine: mock).build(project: proj)
        let ops = await mock.operations
        #expect(built.isEmpty)
        #expect(!ops.contains("builderstart"))
    }

    @Test("up starts the builder when a service builds and the builder is down")
    func upStartsBuilder() async throws {
        let proj = try project("""
        name: demo
        services:
          api:
            build:
              context: ./api
        """)
        let mock = MockEngine()
        await mock.setBuilderUp(false)
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("builderstart"))
        #expect(ops.contains("build:demo-api:compose"))
    }

    @Test("up leaves the builder alone when nothing builds")
    func upNoBuilderWhenNoBuild() async throws {
        let proj = try project("name: demo\nservices:\n  a:\n    image: x\n")
        let mock = MockEngine()
        await mock.setBuilderUp(false)
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let ops = await mock.operations
        #expect(!ops.contains("builderstart"))
    }

    @Test("up waits for a service_healthy dependency before starting the dependent")
    func upWaitsHealthy() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: postgres
            healthcheck:
              test: ["CMD", "pg_isready"]
              interval: 1s
              retries: 5
          app:
            image: x
            depends_on:
              db:
                condition: service_healthy
        """)
        let mock = MockEngine()
        await mock.setExecResults([1, 0])  // unhealthy once, then healthy
        try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj)
        let ops = await mock.operations
        let runDB = try #require(ops.firstIndex(of: "run:demo-db"))
        let execDB = try #require(ops.firstIndex(of: "exec:demo-db"))
        let runApp = try #require(ops.firstIndex(of: "run:demo-app"))
        #expect(runDB < execDB && execDB < runApp)
        #expect(ops.filter { $0 == "exec:demo-db" }.count == 2)
    }

    @Test("up warns and proceeds when a healthy dependency never passes")
    func upHealthyTimeout() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: postgres
            healthcheck:
              test: ["CMD", "false"]
              retries: 3
          app:
            image: x
            depends_on:
              db:
                condition: service_healthy
        """)
        let mock = MockEngine()
        await mock.setExecResults([1, 1, 1, 1])  // always failing
        let warnings = try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("run:demo-app"))  // proceeded anyway
        #expect(ops.filter { $0 == "exec:demo-db" }.count == 3)
        #expect(warnings.contains { $0.severity == .warning && $0.message.contains("did not become healthy") })
    }

    @Test("up waits for a service_completed_successfully dependency")
    func upWaitsCompleted() async throws {
        let proj = try project("""
        name: demo
        services:
          seed:
            image: busybox
          app:
            image: x
            depends_on:
              seed:
                condition: service_completed_successfully
        """)
        let mock = MockEngine()
        await mock.setStates([ContainerState(running: true), ContainerState(running: false, exitCode: 0)])
        try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj)
        let ops = await mock.operations
        let stateIdx = try #require(ops.firstIndex(of: "state:demo-seed"))
        let runApp = try #require(ops.firstIndex(of: "run:demo-app"))
        #expect(stateIdx < runApp)
        #expect(ops.filter { $0 == "state:demo-seed" }.count == 2)
    }

    @Test("up warns when a completed dependency's exit status can't be verified")
    func upWarnsUnverifiableCompletion() async throws {
        let proj = try project("""
        name: demo
        services:
          seed:
            image: busybox
          app:
            image: x
            depends_on:
              seed:
                condition: service_completed_successfully
        """)
        let mock = MockEngine()
        // stops with no exit code (the real Apple container case)
        await mock.setStates([ContainerState(running: true), ContainerState(running: false)])
        let warnings = try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("run:demo-app"))  // proceeds anyway
        #expect(warnings.contains { $0.message.contains("cannot confirm it exited 0") })
    }

    @Test("up does not wait on a dependency excluded by an inactive profile")
    func upSkipsExcludedDependencyReadiness() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: postgres
            profiles: [full]
            healthcheck:
              test: ["CMD", "x"]
          app:
            image: x
            depends_on:
              db:
                condition: service_healthy
        """)
        let mock = MockEngine()
        await mock.setExecResults([1, 1, 1])  // would burn the budget if db were polled
        // no active profiles → db is excluded from the plan
        try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("run:demo-app"))
        #expect(!ops.contains("run:demo-db"))                       // db never started
        #expect(!ops.contains { $0.hasPrefix("exec:") })           // db never polled
    }

    @Test("parseDuration handles compound, bare, and sub-second forms")
    func durationParsing() {
        #expect(ComposeOrchestrator.parseDuration("10s") == 10)
        #expect(ComposeOrchestrator.parseDuration("1m30s") == 90)
        #expect(ComposeOrchestrator.parseDuration("500ms") == 0.5)
        #expect(ComposeOrchestrator.parseDuration("2") == 2)
        #expect(ComposeOrchestrator.parseDuration("1.5s") == 1.5)
        #expect(ComposeOrchestrator.parseDuration(nil) == nil)
        #expect(ComposeOrchestrator.parseDuration("") == nil)
        #expect(ComposeOrchestrator.parseDuration("abc") == nil)
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
