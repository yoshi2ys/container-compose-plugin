import ComposeModel
import ComposeTranslate
import Testing

@testable import ContainerEngine

/// A compose-labelled container, as the engine would report it.
func composeContainer(
    project: String, service: String, name: String? = nil,
    state: String = "running", image: String = "x", ports: [PublishedPort] = []
) -> ContainerSummary {
    ContainerSummary(
        id: name ?? "\(project)-\(service)", image: image, state: state,
        labels: [ComposeLabels.project: project, ComposeLabels.service: service],
        ports: ports)
}

/// Records the sequence of engine operations so tests can assert ordering, and
/// keeps a container store so label-based lookups (`ps`, `down`, the recreate
/// guard, `up`'s post-start check) see a plausible engine state.
actor MockEngine: ContainerEngine {
    var operations: [String] = []
    var running = true
    var builderUp = true
    var containers: [ContainerSummary] = []
    /// Services whose container registers as stopped rather than running.
    var exiting: Set<String> = []

    func setRunning(_ value: Bool) { running = value }
    func setBuilderUp(_ value: Bool) { builderUp = value }
    func setContainers(_ value: [ContainerSummary]) { containers = value }
    func setExiting(_ value: Set<String>) { exiting = value }

    /// Not recorded in `operations`: it is a read, and every command issues it.
    func listContainers() async throws -> [ContainerSummary] { containers }

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
        let name = value(after: "--name", in: argv) ?? "?"
        operations.append("run:\(name)")
        var labels: [String: String] = [:]
        for (index, argument) in argv.enumerated() where argument == "--label" && index + 1 < argv.count {
            let pair = argv[index + 1]
            guard let separator = pair.firstIndex(of: "=") else { continue }
            labels[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
        }
        let service = labels[ComposeLabels.service] ?? ""
        containers.append(ContainerSummary(
            id: name, image: argv.last ?? "",
            state: exiting.contains(service) ? "stopped" : "running", labels: labels))
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
    func remove(name: String, force: Bool) async throws {
        operations.append("rm:\(name)")
        containers.removeAll { $0.id == name }
    }
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
        // nothing exists yet, so nothing is removed: services start in wave order.
        #expect(ops == ["run:demo-base", "run:demo-left", "run:demo-right", "run:demo-top"])
    }

    @Test("up recreates the containers it already owns, remove before run")
    func upRecreatesExisting() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = MockEngine()
        await mock.setContainers([composeContainer(project: "demo", service: "web")])
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(await mock.operations == ["rm:demo-web", "run:demo-web"])
    }

    @Test("up removes the old container when container_name changes")
    func upRemovesRenamedContainer() async throws {
        let proj = try project("""
        name: demo
        services:
          web:
            image: x
            container_name: web-v2
        """)
        let mock = MockEngine()
        // started before container_name was set: same labels, different name. Removing
        // only `web-v2` would leave two containers answering for one service.
        await mock.setContainers([composeContainer(project: "demo", service: "web", name: "web-v1")])
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(await mock.operations == ["rm:web-v1", "run:web-v2"])
    }

    @Test("a one-shot job that exits is not reported as a casualty")
    func upOneShotServiceCompletes() async throws {
        let proj = try project("""
        name: demo
        services:
          seed:
            image: busybox
          web:
            image: x
            depends_on:
              seed:
                condition: service_completed_successfully
        """)
        let mock = MockEngine()
        await mock.setExiting(["seed"])
        await mock.setStates([ContainerState(running: false, exitCode: 0)])
        let result = try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj)
        #expect(result.running == ["web"])
        #expect(result.completed == ["seed"])
        #expect(result.stopped.isEmpty)
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
        await mock.setContainers([
            composeContainer(project: "demo", service: "base"),
            composeContainer(project: "demo", service: "top"),
        ])
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
        let warnings = try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj).warnings
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
        let warnings = try await ComposeOrchestrator(engine: mock, sleep: { _ in }).up(project: proj).warnings
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

    // MARK: - identity by label

    @Test("down removes a container whose service was renamed in the compose file")
    func downRemovesRenamedService() async throws {
        let proj = try project("name: demo\nservices:\n  api:\n    image: x\n")
        let mock = MockEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "api"),
            // started before the service was renamed api → its container is stranded
            // under the old name, and no name-based lookup would ever find it.
            composeContainer(project: "demo", service: "web"),
        ])
        let removed = try await ComposeOrchestrator(engine: mock).down(project: proj)
        // the service the file still defines first, the stranded one after.
        #expect(removed == ["demo-api", "demo-web"])
    }

    @Test("down leaves other projects and unlabelled containers alone")
    func downIgnoresForeignContainers() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = MockEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "web"),
            composeContainer(project: "other", service: "web", name: "other-web"),
            ContainerSummary(id: "buildkit", image: "builder", state: "running"),
        ])
        let removed = try await ComposeOrchestrator(engine: mock).down(project: proj)
        #expect(removed == ["demo-web"])
    }

    @Test("down refuses when the system is not running")
    func downSystemNotRunning() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = MockEngine()
        await mock.setRunning(false)
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).down(project: proj)
        }
        #expect(await mock.operations.isEmpty)
    }

    @Test("ps lists only this project, defined services first")
    func psFiltersByProject() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n  db:\n    image: y\n")
        let mock = MockEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "web"),
            composeContainer(project: "demo", service: "gone"),
            composeContainer(project: "demo", service: "db"),
            composeContainer(project: "other", service: "web", name: "other-web"),
            ContainerSummary(id: "buildkit", image: "builder", state: "running"),
        ])
        let listed = try await ComposeOrchestrator(engine: mock).containers(project: proj)
        #expect(listed.map(\.id) == ["demo-db", "demo-web", "demo-gone"])
    }

    @Test("up will not force-remove a name owned by another project or by nobody")
    func upConflictsAreDetected() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n  db:\n    image: y\n")
        let existing = [
            composeContainer(project: "other", service: "www", name: "demo-web"),
            ContainerSummary(id: "demo-db", image: "y", state: "running"),
        ]
        let conflicts = ComposeOrchestrator.conflicts(
            project: proj, services: ["web", "db"], existing: existing)
        #expect(conflicts == [
            ContainerConflict(name: "demo-db", service: "db", owner: nil),
            ContainerConflict(name: "demo-web", service: "web", owner: "other"),
        ])
    }

    @Test("up treats its own containers as recreatable, not as conflicts")
    func upOwnContainersAreNotConflicts() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let conflicts = ComposeOrchestrator.conflicts(
            project: proj, services: ["web"],
            existing: [composeContainer(project: "demo", service: "web")])
        #expect(conflicts.isEmpty)
    }

    @Test("up stops before mutating anything when a name is taken")
    func upConflictStartsNothing() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = MockEngine()
        await mock.setContainers([composeContainer(project: "other", service: "www", name: "demo-web")])
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).up(project: proj)
        }
        #expect(await mock.operations.isEmpty)
    }

    @Test("up reports which services are running once the last wave finishes")
    func upReportsSettledState() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n  seed:\n    image: y\n")
        let mock = MockEngine()
        await mock.setExiting(["seed"])
        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(result.running == ["web"])
        #expect(result.stopped == ["seed"])
    }

    @Test("a service is resolved by label, and by derived name for unlabelled containers")
    func containerResolution() throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        // renamed container, right labels → found
        let renamed = composeContainer(project: "demo", service: "web", name: "totally-different")
        #expect(ComposeOrchestrator.container(
            for: "web", project: proj, in: [renamed], domain: nil)?.id == "totally-different")
        // no labels, but the name the file implies → found
        let legacy = ContainerSummary(id: "demo-web", image: "x", state: "running")
        #expect(ComposeOrchestrator.container(
            for: "web", project: proj, in: [legacy], domain: nil)?.id == "demo-web")
        // a leftover duplicate must not mask the container under the current name
        let leftover = composeContainer(project: "demo", service: "web", name: "old", state: "running")
        let current = composeContainer(project: "demo", service: "web", state: "stopped")
        #expect(ComposeOrchestrator.container(
            for: "web", project: proj, in: [leftover, current], domain: nil)?.isRunning == false)
    }

    @Test("logs addresses the container the labels point at, not the derived name")
    func logsUsesResolvedName() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = MockEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "web", name: "renamed-web")
        ])
        _ = try await ComposeOrchestrator(engine: mock).logs(
            project: proj, service: "web", follow: true, tail: 5)
        #expect(await mock.operations == ["forward:logs -f -n 5 renamed-web"])
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
