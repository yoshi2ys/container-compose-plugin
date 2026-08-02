import ComposeModel
import ComposeTranslate
import EngineTestSupport
import Testing

@testable import ContainerEngine

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
        let mock = FakeEngine()
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let ops = await mock.operations
        // nothing exists yet, so nothing is removed: services start in wave order.
        #expect(ops == ["run:demo-base", "run:demo-left", "run:demo-right", "run:demo-top"])
    }

    @Test("up recreates the containers it already owns, remove before run")
    func upRecreatesExisting() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
        let built = try await ComposeOrchestrator(engine: mock).build(project: proj, services: ["api"])
        let ops = await mock.operations
        #expect(built == ["api"])
        #expect(ops.contains("build:demo-api:compose"))
        #expect(!ops.contains("build:demo-web:compose"))
    }

    @Test("build starts the builder when it is down")
    func buildStartsBuilder() async throws {
        let proj = try project("name: demo\nservices:\n  api:\n    build:\n      context: ./api\n")
        let mock = FakeEngine()
        await mock.setBuilderUp(false)
        try await ComposeOrchestrator(engine: mock).build(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("builderstart"))
        #expect(ops.contains("build:demo-api:compose"))
    }

    @Test("build --no-cache passes the flag to every build")
    func buildNoCache() async throws {
        let proj = try project("name: demo\nservices:\n  api:\n    build:\n      context: ./api\n")
        let mock = FakeEngine()
        try await ComposeOrchestrator(engine: mock).build(project: proj, noCache: true)
        let invocations = await mock.buildInvocations
        #expect(!invocations.isEmpty)
        #expect(invocations.allSatisfy { $0.contains("--no-cache") })
    }

    @Test("build with no buildable services does nothing and leaves the builder alone")
    func buildNothing() async throws {
        let proj = try project("name: demo\nservices:\n  a:\n    image: x\n")
        let mock = FakeEngine()
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
        let mock = FakeEngine()
        await mock.setBuilderUp(false)
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let ops = await mock.operations
        #expect(ops.contains("builderstart"))
        #expect(ops.contains("build:demo-api:compose"))
    }

    @Test("up leaves the builder alone when nothing builds")
    func upNoBuilderWhenNoBuild() async throws {
        let proj = try project("name: demo\nservices:\n  a:\n    image: x\n")
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
        await mock.setRunning(false)
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).up(project: proj)
        }
        let ops = await mock.operations
        #expect(ops.isEmpty)
    }

    // MARK: - config hash

    private func hashProject(_ image: String = "x") throws -> ComposeProject {
        try project("name: demo\nservices:\n  web:\n    image: \(image)\n")
    }

    /// The container this project would have created for `web` on a previous `up`.
    private func stamped(_ mock: FakeEngine, project: ComposeProject, state: String = "running") async throws {
        try await ComposeOrchestrator(engine: mock).up(project: project)
        let created = try #require(await mock.listContainers().first { $0.composeService == "web" })
        await mock.setContainers([ContainerSummary(
            id: created.id, image: created.image, state: state,
            labels: created.labels, ports: created.ports)])
        await mock.clearOperations()
    }

    @Test("an unchanged service is left running rather than recreated")
    func unchangedServiceIsLeftAlone() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await stamped(mock, project: proj)

        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(result.unchanged == ["web"])
        // Nothing was removed and nothing re-run: whatever it wrote is still there.
        #expect(await mock.operations.isEmpty)
    }

    @Test("an unchanged service that is stopped is started, not recreated")
    func unchangedButStoppedIsStarted() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await stamped(mock, project: proj, state: "stopped")

        _ = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(await mock.operations == ["start:demo-web"])
    }

    @Test("a changed compose file recreates")
    func changedConfigurationRecreates() async throws {
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await stamped(mock, project: try hashProject())

        let edited = try project("""
        name: demo
        services:
          web:
            image: x
            environment:
              ADDED: "1"
        """)
        let result = try await ComposeOrchestrator(engine: mock).up(project: edited)
        #expect(result.unchanged.isEmpty)
        #expect(await mock.operations == ["rm:demo-web", "run:demo-web"])
    }

    /// The point of hashing the image and not just the arguments.
    @Test("the same file recreates when the image behind the tag moved")
    func movedImageRecreates() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await stamped(mock, project: proj)

        await mock.setImageDigests(["x": "sha256:bbb"])  // `docker pull` upstream
        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(result.unchanged.isEmpty)
        #expect(await mock.operations == ["rm:demo-web", "run:demo-web"])
    }

    @Test("--force-recreate recreates an unchanged service")
    func forceRecreate() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await stamped(mock, project: proj)

        let result = try await ComposeOrchestrator(engine: mock).up(project: proj, forceRecreate: true)
        #expect(result.unchanged.isEmpty)
        #expect(await mock.operations == ["rm:demo-web", "run:demo-web"])
    }

    @Test("a container from before hashing existed is recreated once")
    func unlabelledContainerRecreates() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        // labelled by an older build of this plugin: no config-hash
        await mock.setContainers([composeContainer(project: "demo", service: "web")])
        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(result.unchanged.isEmpty)
        #expect(await mock.operations == ["rm:demo-web", "run:demo-web"])
    }

    /// The first `up` on a machine that does not have the image yet used to stamp a
    /// hash with no image id, so the *second* `up` computed a different one and
    /// destroyed a container that had not changed.
    @Test("an image that is not pulled yet is pulled before the fingerprint is taken")
    func imageIsPulledBeforeHashing() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imagesPresent: false)
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(await mock.operations.contains("forward:image pull x"))

        // …so the next `up` sees the same fingerprint and leaves it alone.
        let created = try #require(await mock.listContainers().first { $0.composeService == "web" })
        await mock.setContainers([created])
        await mock.clearOperations()
        let second = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(second.unchanged == ["web"])
    }

    @Test("a service with both build: and image: hashes the image it will actually run")
    func buildAndImageHashesTheRunImage() async throws {
        let proj = try project("""
        name: demo
        services:
          web:
            build: ./web
            image: myapp:dev
        """)
        let mock = FakeEngine(imageDigests: ["myapp:dev": "sha256:aaa", "demo-web:compose": "sha256:zzz"])
        try await stamped(mock, project: proj)

        // The build tag moves; the image the container runs does not.
        await mock.setImageDigests(["myapp:dev": "sha256:aaa", "demo-web:compose": "sha256:different"])
        #expect(try await ComposeOrchestrator(engine: mock).up(project: proj).unchanged == ["web"])

        // The run image moves; that must recreate.
        await mock.setImageDigests(["myapp:dev": "sha256:bbb", "demo-web:compose": "sha256:different"])
        #expect(try await ComposeOrchestrator(engine: mock).up(project: proj).unchanged.isEmpty)
    }

    @Test("a stopped container that refuses to start is recreated rather than failing up")
    func unresumableContainerIsRecreated() async throws {
        let proj = try hashProject()
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await stamped(mock, project: proj, state: "stopped")
        await mock.setStartFails(true)

        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(result.unchanged.isEmpty)
        #expect(await mock.operations == ["start:demo-web", "rm:demo-web", "run:demo-web"])
    }

    @Test("the created container carries the fingerprint")
    func containerIsStamped() async throws {
        let mock = FakeEngine(imageDigests: ["x": "sha256:aaa"])
        try await ComposeOrchestrator(engine: mock).up(project: try hashProject())
        let created = try #require(await mock.listContainers().first)
        #expect(created.labels[ComposeLabels.configHash]?.count == 64)  // hex SHA-256
    }

    // MARK: - service-name DNS

    private func dnsProject() throws -> ComposeProject {
        try project("""
        name: demo
        services:
          web:
            image: x
          db:
            image: y
        """)
    }

    @Test("with no registered domain, names stay unqualified and the fix is suggested")
    func noDomainKeepsPlainNames() async throws {
        let mock = FakeEngine()
        let result = try await ComposeOrchestrator(engine: mock).up(project: try dnsProject())
        #expect(await mock.operations == ["run:demo-db", "run:demo-web"])
        let hint = try #require(result.warnings.first { $0.key == "dns" })
        // A suggestion, so it stays out of the way until `--verbose` or `config`.
        #expect(hint.severity == .info)
        #expect(hint.message.contains("container system dns create"))
    }

    @Test("a registered domain qualifies every name under <project>.<domain>")
    func registeredDomainQualifiesNames() async throws {
        let mock = FakeEngine(dnsDomains: ["test"])
        try await ComposeOrchestrator(engine: mock).up(project: try dnsProject())
        #expect(await mock.operations.filter { $0.hasPrefix("run:") }
            == ["run:db.demo.test", "run:web.demo.test"])
    }

    @Test("the run argv carries --dns-search so a sibling is reachable by its short name")
    func dnsSearchIsAdded() async throws {
        let mock = FakeEngine(dnsDomains: ["test"])
        try await ComposeOrchestrator(engine: mock).up(project: try dnsProject())
        let argv = try #require(await mock.runInvocations.first)
        #expect(argv.firstIndex(of: "--dns-search").map { argv[$0 + 1] } == "demo.test")
    }

    /// The whole point of the probe: a domain being registered is not evidence that
    /// anything resolves.
    @Test("a registered domain whose names do not resolve is reported, not assumed to work")
    func brokenResolutionIsReported() async throws {
        let working = FakeEngine(dnsDomains: ["test"], resolutionWorks: true)
        let quiet = try await ComposeOrchestrator(engine: working).up(project: try dnsProject())
        #expect(!quiet.warnings.contains { $0.message.contains("cannot resolve") })

        let broken = FakeEngine(dnsDomains: ["test"], resolutionWorks: false)
        let loud = try await ComposeOrchestrator(engine: broken).up(project: try dnsProject())
        let warning = try #require(loud.warnings.first { $0.key == "dns" && $0.severity == .warning })
        // names the service that actually ran the probe, not whatever sorted first
        #expect(warning.message.contains("'db' cannot resolve"))
        #expect(warning.severity == .warning)
        #expect(warning.message.contains("HOST_GATEWAY"))
        #expect(warning.message.contains("macOS 27 developer beta"))
        // the stack is up regardless — DNS is the nicer path, not the only one
        #expect(loud.running == ["db", "web"])
    }

    @Test("a domain named after the project wins over the others")
    func preferredDomainSelection() throws {
        let proj = try dnsProject()
        #expect(ComposeOrchestrator.preferredDomain(["zulu", "demo", "alpha"], project: proj) == "demo")
        // otherwise a stable choice, not whatever order the engine happened to print
        #expect(ComposeOrchestrator.preferredDomain(["zulu", "alpha"], project: proj) == "alpha")
        #expect(ComposeOrchestrator.preferredDomain([], project: proj) == nil)
    }

    @Test("a service named by container_name is not used as the probe target")
    func probeSkipsUnqualifiedTargets() async throws {
        // `db` is deliberately outside the domain, so failing to resolve it says
        // nothing about the host — blaming the resolver there would be wrong.
        let proj = try project("""
        name: demo
        services:
          app:
            image: x
          db:
            image: y
            container_name: legacy-db
        """)
        let mock = FakeEngine(dnsDomains: ["test"], resolutionWorks: false)
        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        // The container_name warning is expected; the host-blaming probe one is not.
        #expect(result.warnings.contains { $0.key == "container_name" })
        #expect(!result.warnings.contains { $0.key == "dns" && $0.severity == .warning })
    }

    @Test("no probe when there is nothing to resolve against")
    func noProbeForASingleService() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = FakeEngine(dnsDomains: ["test"], resolutionWorks: false)
        let result = try await ComposeOrchestrator(engine: mock).up(project: proj)
        #expect(!result.warnings.contains { $0.message.contains("cannot resolve") })
    }

    @Test("down and logs still find containers named under a domain, by label")
    func labelLookupSurvivesQualifiedNames() async throws {
        let proj = try dnsProject()
        let mock = FakeEngine(dnsDomains: ["test"])
        try await ComposeOrchestrator(engine: mock).up(project: proj)
        let removed = try await ComposeOrchestrator(engine: mock).down(project: proj)
        #expect(removed == ["web.demo.test", "db.demo.test"])
    }

    // MARK: - identity by label

    @Test("down removes a container whose service was renamed in the compose file")
    func downRemovesRenamedService() async throws {
        let proj = try project("name: demo\nservices:\n  api:\n    image: x\n")
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "api"),
            // started before the service was renamed api → its container is stranded
            // under the old name, and no name-based lookup would ever find it.
            composeContainer(project: "demo", service: "web"),
        ])
        let removed = try await ComposeOrchestrator(engine: mock).down(project: proj)
        // The stranded container goes first on this reverse pass: nothing in the file
        // depends on it, but it may depend on a service the file still describes.
        #expect(removed == ["demo-web", "demo-api"])
    }

    @Test("down leaves other projects and unlabelled containers alone")
    func downIgnoresForeignContainers() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "web"),
            composeContainer(project: "other", service: "web", name: "other-web"),
            ContainerSummary(id: "buildkit", image: "builder", state: "running"),
        ])
        let removed = try await ComposeOrchestrator(engine: mock).down(project: proj)
        #expect(removed == ["demo-web"])
    }

    @Test("stop and start skip a service the active profiles exclude")
    func lifecycleRespectsProfiles() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: x
          web:
            image: x
            depends_on: [db]
          debug:
            image: x
            profiles: [debug]
            depends_on: [db]
        """)
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "db", state: "stopped"),
            composeContainer(project: "demo", service: "web", state: "stopped"),
            composeContainer(project: "demo", service: "debug", state: "stopped"),
        ])
        // `up` with no profile would not start `debug`, so neither does `start`.
        let started = try await ComposeOrchestrator(engine: mock).start(project: proj)
        #expect(started == ["demo-db", "demo-web"])
    }

    @Test("stop covers a profile-excluded service, which start would have left alone")
    func stopCoversExcludedServices() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: x
          debug:
            image: x
            profiles: [debug]
            depends_on: [db]
        """)
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "db"),
            composeContainer(project: "demo", service: "debug"),
        ])
        // Started with `--profile debug`; without it, `stop` still has to reach it,
        // or the container is left running with no command that will stop it.
        let stopped = try await ComposeOrchestrator(engine: mock).stop(project: proj)
        #expect(stopped == ["demo-debug", "demo-db"])
    }

    @Test("restart puts back exactly what it took down, profiles included")
    func restartIsSymmetric() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: x
          debug:
            image: x
            profiles: [debug]
            depends_on: [db]
        """)
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "db"),
            composeContainer(project: "demo", service: "debug"),
        ])
        let restarted = try await ComposeOrchestrator(engine: mock).restart(project: proj)
        #expect(restarted == ["demo-db", "demo-debug"])
        #expect(await mock.operations == [
            "stop:demo-debug", "stop:demo-db", "start:demo-db", "start:demo-debug",
        ])
    }

    @Test("stop unwinds a service that is gone from the file before the ones that remain")
    func stopOrphansFirst() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: x
          web:
            image: x
            depends_on: [db]
        """)
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "db"),
            composeContainer(project: "demo", service: "web"),
            // left from a service that has since been deleted; it may still depend on db
            composeContainer(project: "demo", service: "gone"),
        ])
        let stopped = try await ComposeOrchestrator(engine: mock).stop(project: proj)
        #expect(stopped == ["demo-gone", "demo-web", "demo-db"])
    }

    @Test("down orders a profile-excluded service by its dependencies, not as an afterthought")
    func downOrdersExcludedServicesProperly() async throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: x
          debug:
            image: x
            profiles: [debug]
            depends_on: [db]
        """)
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "db"),
            composeContainer(project: "demo", service: "debug"),
        ])
        // No active profile, but `debug` is still a defined service that depends on
        // `db`, so it has to be torn down first.
        let removed = try await ComposeOrchestrator(engine: mock).down(project: proj)
        #expect(removed == ["demo-debug", "demo-db"])
    }

    @Test("restart brings up a stack that was already stopped")
    func restartStartsAStoppedStack() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = FakeEngine()
        await mock.setContainers([
            composeContainer(project: "demo", service: "web", state: "stopped")
        ])
        let restarted = try await ComposeOrchestrator(engine: mock).restart(project: proj)
        #expect(restarted == ["demo-web"])
        // nothing to stop, so no pointless `container stop` on a stopped container
        #expect(await mock.operations == ["start:demo-web"])
    }

    @Test("down refuses when the system is not running")
    func downSystemNotRunning() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = FakeEngine()
        await mock.setRunning(false)
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).down(project: proj)
        }
        #expect(await mock.operations.isEmpty)
    }

    @Test("ps lists only this project, defined services first")
    func psFiltersByProject() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n  db:\n    image: y\n")
        let mock = FakeEngine()
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
            project: proj, services: ["web", "db"], existing: existing, domain: nil)
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
            existing: [composeContainer(project: "demo", service: "web")], domain: nil)
        #expect(conflicts.isEmpty)
    }

    @Test("up stops before mutating anything when a name is taken")
    func upConflictStartsNothing() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n")
        let mock = FakeEngine()
        await mock.setContainers([composeContainer(project: "other", service: "www", name: "demo-web")])
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).up(project: proj)
        }
        #expect(await mock.operations.isEmpty)
    }

    @Test("up reports which services are running once the last wave finishes")
    func upReportsSettledState() async throws {
        let proj = try project("name: demo\nservices:\n  web:\n    image: x\n  seed:\n    image: y\n")
        let mock = FakeEngine()
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
        let mock = FakeEngine()
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
        let mock = FakeEngine()
        await #expect(throws: OrchestratorError.self) {
            try await ComposeOrchestrator(engine: mock).up(project: proj)
        }
        let ops = await mock.operations
        #expect(ops.isEmpty)
    }
}
