import ComposeGraph
import ComposeModel
import ComposeTranslate
import Foundation

public enum OrchestratorError: Error, Sendable {
    case systemNotRunning
    case graph(GraphError)
    case blocking([Warning])
    /// `up` would have to destroy containers it does not own. Never done silently.
    case conflict([ContainerConflict])
}

/// A container occupying a name this project needs, owned by someone else.
/// `owner` is the other project's label, or `nil` when the container carries no
/// compose labels at all (created by hand, or by `container run`).
public struct ContainerConflict: Sendable, Equatable {
    public let name: String
    public let service: String
    public let owner: String?

    public init(name: String, service: String, owner: String?) {
        self.name = name
        self.service = service
        self.owner = owner
    }
}

/// What `up` did, beyond the warnings it collected.
public struct UpResult: Sendable, Equatable {
    public let warnings: [Warning]
    /// Services whose container is running once the last wave finishes.
    public let running: [String]
    /// Services that have exited and were meant to: a one-shot job another service
    /// waits on with `depends_on: service_completed_successfully`.
    public let completed: [String]
    /// Services that are not running and were not meant to exit.
    public let stopped: [String]

    public init(warnings: [Warning], running: [String], completed: [String], stopped: [String]) {
        self.warnings = warnings
        self.running = running
        self.completed = completed
        self.stopped = stopped
    }

    /// Every service `up` tried to start.
    public var total: Int { running.count + completed.count + stopped.count }
}

/// Drives `up` / `down` / `ps` / `logs` over a `ContainerEngine`, using the pure
/// core (graph for ordering, translate for argv).
public struct ComposeOrchestrator: Sendable {
    let engine: any ContainerEngine
    /// Sleep between readiness polls. Injectable so tests run instantly.
    let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        engine: any ContainerEngine,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        }
    ) {
        self.engine = engine
        self.sleep = sleep
    }

    /// Bring the stack up: create prerequisites, then start services wave by wave
    /// (dependency order). Validates the whole project before mutating anything, so
    /// a blocking error — including a name owned by another project — starts nothing.
    @discardableResult
    public func up(
        project: ComposeProject,
        activeProfiles: Set<String> = [],
        options: TranslateOptions = TranslateOptions()
    ) async throws -> UpResult {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }

        let plan: StartupPlan
        switch ComposeGraph.startupPlan(project, activeProfiles: activeProfiles) {
        case .success(let value): plan = value
        case .failure(let error): throw OrchestratorError.graph(error)
        }

        // Inject the host gateway as HOST_GATEWAY. It stays even when service-name
        // DNS is in play: DNS is the nicer path, this is the one that always works.
        var options = options
        if options.hostGateway == nil {
            options.hostGateway = try? await engine.hostGateway()
        }
        // A registered local DNS domain turns container names into FQDNs, which is
        // what puts them in the engine's resolver. Best-effort: an engine without the
        // subcommand simply has no domains.
        if options.dnsDomain == nil {
            let registered = Self.preferredDomain(
                (try? await engine.dnsDomains()) ?? [], project: project)
            options.dnsDomain = ComposeNaming.dnsDomain(project: project, registered: registered)
        }
        let domain = options.dnsDomain

        // Translate everything first; refuse to start if anything is blocking.
        var warnings: [Warning] = []
        var runArgsByService: [String: [String]] = [:]
        let order = plan.waves.flatMap { $0 }
        let started = Set(order)
        for serviceName in order {
            let result = ComposeTranslate.runArgs(serviceName: serviceName, project: project, options: options)
            warnings.append(contentsOf: result.warnings)
            runArgsByService[serviceName] = result.argv
        }
        let blocking = warnings.filter { $0.severity == .blocking }
        guard blocking.isEmpty else { throw OrchestratorError.blocking(blocking) }

        // Recreating a service force-removes whatever holds its name. Check ownership
        // by label first: a container belonging to another project, or to nobody, is
        // not ours to destroy.
        let existing = try await engine.listContainers()
        let conflicts = Self.conflicts(
            project: project, services: order, existing: existing, domain: domain)
        guard conflicts.isEmpty else { throw OrchestratorError.conflict(conflicts) }

        // `build:` needs the BuildKit builder up, or `container build` hangs and times
        // out; start it on demand before any build runs.
        if order.contains(where: { project.services[$0]?.build != nil }) {
            try await ensureBuilderRunning()
        }

        // Prerequisites (idempotent; "already exists" is fine to ignore).
        for prerequisite in ComposeTranslate.prerequisites(project) {
            switch prerequisite {
            case .network(_, let argv): try? await engine.createNetwork(argv: argv)
            case .volume(_, let argv): try? await engine.createVolume(argv: argv)
            }
        }

        // Start wave by wave, recreating each container so `up` is idempotent and
        // recovers from a partial prior run; named volumes persist, so data is kept.
        for wave in plan.waves {
            for serviceName in wave {
                guard let service = project.services[serviceName] else { continue }
                // Emulate `depends_on` health/completion conditions (Apple container has
                // no native healthcheck): wait on each dependency before starting. Skip
                // dependencies not in the startup plan (e.g. excluded by an inactive
                // profile) — they are never started, so there is nothing to wait for.
                for dependency in service.dependsOn
                where dependency.condition != .started && started.contains(dependency.service) {
                    if let warning = try await awaitReadiness(dependency, in: project, domain: domain) {
                        warnings.append(warning)
                    }
                }
                if service.build != nil,
                    let build = ComposeTranslate.buildArgs(
                        serviceName: serviceName, project: project, baseDirectory: options.baseDirectory) {
                    try await engine.build(argv: build.argv)
                }
                if let argv = runArgsByService[serviceName] {
                    // Remove every container this project already has for the service,
                    // not just the one under the name the file implies now: changing
                    // `container_name` would otherwise leave the old one running with
                    // the same labels, and two containers would answer for one service.
                    for stale in Self.staleContainers(
                        for: serviceName, project: project, in: existing, domain: domain) {
                        try? await engine.remove(name: stale.id, force: true)
                    }
                    _ = try await engine.run(argv: argv)
                }
            }
        }

        // Ask the engine what actually survived, so a service that dies on startup is
        // not counted as started.
        let settled = try await engine.listContainers()
        let oneShot = Self.oneShotServices(project)
        var running: [String] = []
        var completed: [String] = []
        var stopped: [String] = []
        for serviceName in order.sorted() {
            let container = Self.container(
                for: serviceName, project: project, in: settled, domain: domain)
            if container?.isRunning == true {
                running.append(serviceName)
            } else if oneShot.contains(serviceName) {
                completed.append(serviceName)
            } else {
                stopped.append(serviceName)
            }
        }
        if let domain {
            if let probe = await resolutionWarning(
                project: project, domain: domain, running: running, containers: settled) {
                warnings.append(probe)
            }
        } else {
            // Info, not a warning: it is a suggestion, and it would otherwise nag on
            // every `up` of every stack that does not need service-name DNS.
            warnings.append(Warning(
                kind: .engineGap(.serviceNameDNS), key: "dns",
                message: "No local DNS domain is registered, so services cannot reach each other by "
                    + "name; they use HOST_GATEWAY and published ports. "
                    + "`sudo container system dns create test` turns on name resolution.",
                severity: .info))
        }
        return UpResult(
            warnings: warnings, running: running, completed: completed, stopped: stopped)
    }

    /// Build (or rebuild) images for services that declare a `build:` section —
    /// the Compose `build` command. `services`, when non-empty, restricts the set to
    /// those names (assumed to exist; the CLI validates first); profiles do not affect
    /// `build`. With `noCache`, the builder ignores its layer cache. Returns the
    /// service names actually built.
    @discardableResult
    public func build(
        project: ComposeProject,
        services: [String] = [],
        noCache: Bool = false,
        baseDirectory: String? = nil
    ) async throws -> [String] {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }

        // `buildArgs` is the single authority on what is buildable — it returns nil for
        // image-only services, so `compactMap` doubles as the filter.
        let requested = services.isEmpty ? project.serviceNames : services
        let builds = requested.compactMap { name in
            ComposeTranslate.buildArgs(
                serviceName: name, project: project, baseDirectory: baseDirectory, noCache: noCache)
                .map { (service: name, argv: $0.argv) }
        }
        guard !builds.isEmpty else { return [] }

        try await ensureBuilderRunning()
        for item in builds { try await engine.build(argv: item.argv) }
        return builds.map(\.service)
    }

    /// Stop and remove every container labelled with this project, in reverse
    /// dependency order. Errors per container are ignored (already gone / never
    /// started).
    ///
    /// The set comes from labels, not from names: renaming a service in the compose
    /// file would otherwise strand the container started under the old name. A
    /// container whose service is no longer in the file is removed *first*, since
    /// nothing the file describes depends on it while it may depend on them.
    ///
    /// Profiles do not narrow this: `down` removes the whole project, so it takes no
    /// profile set — passing one would suggest otherwise.
    @discardableResult
    public func down(project: ComposeProject) async throws -> [String] {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }

        // Every defined service takes part in the ordering, profile-excluded ones
        // included: they still own containers this removes, and ordering them as an
        // afterthought would drop them out of the dependency order.
        let order: [String]
        switch ComposeGraph.startupPlan(project, activeProfiles: []) {
        case .success(let plan): order = plan.shutdownOrder
        case .failure: order = project.serviceNames.reversed()
        }

        // What is left carries our label but matches no service in the file — a
        // renamed or deleted one. It goes first on this reverse pass, since it may
        // depend on a service the file still describes.
        let (ordered, rest) = try await partition(project: project, services: order)
        let names = (rest + ordered).map(\.id)

        for name in names {
            try? await engine.stop(name: name, timeout: nil)
            try? await engine.remove(name: name, force: true)
        }
        return names
    }

    /// The project's containers, running or not, ordered by service name with
    /// containers for undefined services last. Other projects' containers, and the
    /// engine's own (`buildkit`), are excluded.
    public func containers(project: ComposeProject) async throws -> [ContainerSummary] {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }
        let defined = Set(project.serviceNames)
        return try await ownedContainers(project: project).sorted { lhs, rhs in
            let left = lhs.composeService ?? ""
            let right = rhs.composeService ?? ""
            if defined.contains(left) != defined.contains(right) { return defined.contains(left) }
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    /// Stop the project's running containers in shutdown order, leaving them in
    /// place. Returns the containers it stopped.
    ///
    /// Stops **everything** the project owns, profiles included: leaving a container
    /// running that `stop` will not stop again is worse than stopping one extra.
    @discardableResult
    public func stop(project: ComposeProject, activeProfiles: Set<String> = []) async throws -> [String] {
        try await apply(
            project: project, activeProfiles: activeProfiles, reversed: true, scope: .everythingOwned
        ) { container in
            guard container.isRunning else { return false }
            try await engine.stop(name: container.id, timeout: nil)
            return true
        }
    }

    /// Start the project's stopped containers in dependency order.
    ///
    /// Only the services the active profiles include: `up` would not start a
    /// profile-excluded service, so neither does `start`.
    @discardableResult
    public func start(project: ComposeProject, activeProfiles: Set<String> = []) async throws -> [String] {
        try await apply(
            project: project, activeProfiles: activeProfiles, reversed: false, scope: .activeProfiles
        ) { container in
            guard !container.isRunning else { return false }
            try await engine.start(name: container.id)
            return true
        }
    }

    /// Stop then start the project's containers — stopping in shutdown order and
    /// starting in dependency order, so a restart never leaves a dependent running
    /// without its dependency.
    ///
    /// Ends with every container the project owns running, profiles included — the
    /// same contract as `docker compose restart`, which also starts a container that
    /// was already stopped. Only the running ones are stopped first; the rest have
    /// nothing to stop.
    @discardableResult
    public func restart(project: ComposeProject, activeProfiles: Set<String> = []) async throws -> [String] {
        _ = try await apply(
            project: project, activeProfiles: activeProfiles, reversed: true, scope: .everythingOwned
        ) { container in
            guard container.isRunning else { return false }
            try await engine.stop(name: container.id, timeout: nil)
            return true
        }
        return try await apply(
            project: project, activeProfiles: activeProfiles, reversed: false, scope: .everythingOwned
        ) { container in
            try await engine.start(name: container.id)
            return true
        }
    }

    /// Pull the images of services that name one. `services`, when non-empty,
    /// restricts the set. Returns the image references pulled.
    @discardableResult
    public func pull(project: ComposeProject, services: [String] = []) async throws -> [String] {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }
        // `build:`-only services have no image to pull; `build` covers those.
        let requested = services.isEmpty ? project.serviceNames : services
        var seen: Set<String> = []
        let images = requested.compactMap { project.services[$0]?.image }.filter { seen.insert($0).inserted }
        var pulled: [String] = []
        for image in images {
            let code = try await engine.forward(argv: ["image", "pull", image])
            guard code == 0 else {
                throw EngineError(argv: ["image", "pull", image], exitCode: code, stderr: "")
            }
            pulled.append(image)
        }
        return pulled
    }

    /// Run a command inside a service's container, with this process's stdio
    /// attached. Returns the command's exit code.
    ///
    /// Uses `forward`, not `engine.exec`: the latter captures output and cannot
    /// support an interactive session. `tty` must reflect whether stdin really is a
    /// terminal — `container exec -t` fails with "Operation not supported by device"
    /// when it is not, which would break every scripted `exec`.
    public func exec(
        project: ComposeProject, service: String, command: [String], tty: Bool
    ) async throws -> Int32 {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }
        let name = try await resolvedName(service: service, project: project)
        return try await engine.forward(argv: ["exec", "-i"] + (tty ? ["-t"] : []) + [name] + command)
    }

    /// Applies `action` to the project's containers in dependency order (or its
    /// reverse), returning the names it acted on.
    ///
    /// Containers outside `scope` — a service gone from the file, and under
    /// `.activeProfiles` also one the profiles exclude — are unwound first and built
    /// up last: nothing in the file depends on them, but they may depend on
    /// something that is in it.
    /// Which of the project's containers a lifecycle command acts on.
    enum Scope {
        /// Only the services the active profiles include, plus containers whose
        /// service is gone from the file.
        case activeProfiles
        /// Every container carrying the project's label.
        case everythingOwned
    }

    private func apply(
        project: ComposeProject,
        activeProfiles: Set<String>,
        reversed: Bool,
        scope: Scope,
        action: (ContainerSummary) async throws -> Bool
    ) async throws -> [String] {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }

        var order: [String]
        switch ComposeGraph.startupPlan(project, activeProfiles: activeProfiles) {
        case .success(let plan): order = reversed ? plan.shutdownOrder : plan.waves.flatMap { $0 }
        case .failure: order = reversed ? project.serviceNames.reversed() : project.serviceNames
        }

        let (ordered, rest) = try await partition(project: project, services: order)
        // Whatever `order` does not cover goes first when unwinding and last when
        // building up: nothing in the file depends on it, but it may depend on
        // something that is.
        let defined = Set(project.serviceNames)
        let extras = scope == .everythingOwned
            ? rest
            : rest.filter { !defined.contains($0.composeService ?? "") }
        let targets = reversed ? extras + ordered : ordered + extras

        var acted: [String] = []
        for container in targets {
            if try await action(container) { acted.append(container.id) }
        }
        return acted
    }

    /// Splits the project's containers into those matching `services`, in that order,
    /// and everything else the project owns.
    private func partition(
        project: ComposeProject, services: [String]
    ) async throws -> (ordered: [ContainerSummary], rest: [ContainerSummary]) {
        let owned = try await ownedContainers(project: project)
        let byService = Dictionary(grouping: owned) { $0.composeService ?? "" }
        let covered = Set(services)
        return (
            services.flatMap { byService[$0] ?? [] },
            owned.filter { !covered.contains($0.composeService ?? "") }
        )
    }

    /// Follow the logs of every service in the project at once, handing each line to
    /// `onLine` with the service it came from.
    ///
    /// One task per service, none of them going through the engine's serialized
    /// spawn path — otherwise the first stream would hold it for the lifetime of the
    /// stack. Returns when every stream ends, or when the surrounding task is
    /// cancelled (which terminates the readers).
    public func follow(
        project: ComposeProject,
        activeProfiles: Set<String> = [],
        services: [String]? = nil,
        follow: Bool = true,
        tail: Int? = nil,
        onLine: @escaping @Sendable (String, String) -> Void
    ) async throws {
        let included = services.map(Set.init)
            ?? ComposeGraph.includedServices(project, activeProfiles: activeProfiles)
        let containers = try await engine.listContainers()
        let targets = project.serviceNames.filter(included.contains).compactMap { service in
            Self.container(for: service, project: project, in: containers, domain: nil)
                .map { (service: service, name: $0.id) }
        }
        guard !targets.isEmpty else { return }

        let engine = self.engine
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    _ = try? await engine.streamLogs(
                        name: target.name, follow: follow, tail: tail
                    ) { line in
                        onLine(target.service, line)
                    }
                }
            }
        }
    }

    /// Stream logs for a service (or the first service) — passthrough to `container logs`.
    @discardableResult
    public func logs(project: ComposeProject, service: String?, follow: Bool, tail: Int?) async throws -> Int32 {
        guard let serviceName = service ?? project.serviceNames.first else { return 1 }
        let name = try await resolvedName(service: serviceName, project: project)
        var argv = ["logs"]
        if follow { argv += ["-f"] }
        if let tail { argv += ["-n", "\(tail)"] }
        argv += [name]
        return try await engine.forward(argv: argv)
    }

    // MARK: - service-name DNS

    /// Checks that a service can actually resolve a sibling by name, and explains it
    /// if not.
    ///
    /// A registered domain is not evidence that resolution works. The engine's
    /// resolver listens on the host's loopback, and the container reaches it through
    /// the host's system resolver; if that link is not wired up, every name is
    /// registered and none of them resolves. Measured on macOS 26A5388g with
    /// container 1.1.0: `dig @127.0.0.1 -p 2053 web.demo.test` answers while
    /// mDNSResponder returns "No Such Record" for the same name, so containers get
    /// NXDOMAIN. macOS 27 is a developer beta at the time of writing, so this may
    /// well be fixed in a later build — hence a runtime probe rather than a version
    /// check or a blanket "unsupported".
    ///
    /// `HOST_GATEWAY` is injected either way, so a failing probe costs the user a
    /// warning, not a broken stack.
    private func resolutionWarning(
        project: ComposeProject, domain: String, running: [String], containers: [ContainerSummary]
    ) async -> Warning? {
        // Needs somewhere to ask from, and a target that is actually under the
        // domain — a service with an explicit `container_name` is not, and asking
        // about it would blame the host for the compose file's own choice.
        let started = running.compactMap {
            Self.container(for: $0, project: project, in: containers, domain: domain)
        }
        guard let from = started.first,
            let target = started.dropFirst().first(where: { $0.id.hasSuffix(".\(domain)") })
        else { return nil }

        // Whichever of these the image has.
        let probe = "getent hosts \(target.id) || nslookup \(target.id) || ping -c1 -w1 \(target.id)"
        guard let code = try? await engine.exec(name: from.id, argv: ["sh", "-c", probe]) else { return nil }
        // 126/127 mean the shell or the tools are missing, not that the name failed
        // to resolve. A distroless image must not be reported as broken DNS.
        guard code != 0, code != 126, code != 127 else { return nil }

        return Warning(
            kind: .engineGap(.serviceNameDNS), key: "dns",
            message: "Containers are named under '\(domain)', but "
                + "'\(from.composeService ?? from.id)' cannot resolve "
                + "'\(target.id)'. The domain is registered with the engine and the names are in "
                + "its resolver, yet the host does not answer for them — on macOS that is the "
                + "/etc/resolver wiring, which is broken on the macOS 27 developer beta and may be "
                + "fixed in a later build. Until then, reach siblings through HOST_GATEWAY and "
                + "their published ports; nothing else in the stack is affected.",
            severity: .warning)
    }

    /// Which registered domain a project uses: one named after the project when the
    /// user registered such a domain, otherwise the first in a stable order. Sorted
    /// rather than "as listed" so the choice does not depend on the engine's output
    /// order, which would rename every container when it changed.
    static func preferredDomain(_ registered: [String], project: ComposeProject) -> String? {
        let name = ComposeNaming.projectName(project)
        return registered.first { $0 == name } ?? registered.sorted().first
    }

    // MARK: - identity

    /// Containers carrying this project's label.
    private func ownedContainers(project: ComposeProject) async throws -> [ContainerSummary] {
        let name = ComposeNaming.projectName(project)
        return try await engine.listContainers().filter { $0.composeProject == name }
    }

    /// The container name to address a service by: the one the engine actually has
    /// under our labels, falling back to the name the file implies (it may not be
    /// created yet).
    private func resolvedName(service: String, project: ComposeProject) async throws -> String {
        let containers = try await engine.listContainers()
        return Self.container(for: service, project: project, in: containers, domain: nil)?.id
            ?? ComposeNaming.containerName(project: project, service: service, domain: nil)
    }

    /// Every container this project holds for `service`: the label-matched ones,
    /// plus whatever occupies the name the file implies now. `up` removes all of
    /// them before recreating, so a rename leaves nothing behind.
    static func staleContainers(
        for service: String, project: ComposeProject, in containers: [ContainerSummary], domain: String?
    ) -> [ContainerSummary] {
        let projectName = ComposeNaming.projectName(project)
        let derived = ComposeNaming.containerName(project: project, service: service, domain: domain)
        return containers.filter {
            ($0.composeProject == projectName && $0.composeService == service) || $0.id == derived
        }
    }

    /// The container belonging to `service` in `project`. Prefers the one under the
    /// name the file implies, so a leftover duplicate cannot mask the current
    /// container's state; falls back to the derived name alone for containers that
    /// predate labelling.
    static func container(
        for service: String, project: ComposeProject, in containers: [ContainerSummary], domain: String?
    ) -> ContainerSummary? {
        let candidates = staleContainers(
            for: service, project: project, in: containers, domain: domain)
        let derived = ComposeNaming.containerName(project: project, service: service, domain: domain)
        return candidates.first { $0.id == derived } ?? candidates.first
    }

    /// Services that are meant to exit: the ones another service waits to complete.
    /// Apple `container` does not report a stopped container's exit code, so a
    /// one-shot job's *success* is unverifiable — but treating its exit as a failure
    /// would flag every correct `up` of a seed/migration job.
    static func oneShotServices(_ project: ComposeProject) -> Set<String> {
        Set(project.services.values.flatMap { service in
            service.dependsOn
                .filter { $0.condition == .completedSuccessfully }
                .map(\.service)
        })
    }

    /// Names this `up` would have to force-remove that belong to another project, or
    /// to no compose project at all.
    static func conflicts(
        project: ComposeProject, services: [String], existing: [ContainerSummary], domain: String?
    ) -> [ContainerConflict] {
        let projectName = ComposeNaming.projectName(project)
        let byName = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return services.sorted().compactMap { service in
            let name = ComposeNaming.containerName(project: project, service: service, domain: domain)
            guard let container = byName[name] else { return nil }
            let owner = container.composeProject
            guard owner != projectName else { return nil }
            return ContainerConflict(name: name, service: service, owner: owner)
        }
    }

    /// Start the BuildKit builder if it is down — `container build` hangs and times
    /// out without it. Idempotent (only starts when `builderRunning` reports false).
    private func ensureBuilderRunning() async throws {
        if !(try await engine.builderRunning()) { try await engine.startBuilder() }
    }

    // MARK: - readiness (depends_on conditions)

    /// Block until `dependency` satisfies its condition. Returns a warning (and proceeds)
    /// if it times out — `up` is best-effort and must never hang.
    private func awaitReadiness(
        _ dependency: Dependency, in project: ComposeProject, domain: String?
    ) async throws -> Warning? {
        let name = ComposeNaming.containerName(
            project: project, service: dependency.service, domain: domain)
        switch dependency.condition {
        case .started:
            return nil
        case .healthy:
            // No usable healthcheck → fall back to start-order (the dependency is already up).
            guard let healthcheck = project.services[dependency.service]?.healthcheck,
                healthcheck.disable != true,
                let command = Self.healthcheckCommand(healthcheck.test)
            else { return nil }
            return try await pollHealthy(name: name, service: dependency.service, healthcheck: healthcheck, command: command)
        case .completedSuccessfully:
            return try await pollCompleted(name: name, service: dependency.service)
        }
    }

    private func pollHealthy(
        name: String, service: String, healthcheck: Healthcheck, command: [String]
    ) async throws -> Warning? {
        let interval = Self.parseDuration(healthcheck.interval) ?? 1.0
        let retries = max(1, healthcheck.retries ?? 30)
        if let startPeriod = Self.parseDuration(healthcheck.startPeriod), startPeriod > 0 {
            try await sleep(startPeriod)
        }
        for attempt in 1...retries {
            if try await engine.exec(name: name, argv: command) == 0 { return nil }
            if attempt < retries { try await sleep(interval) }
        }
        return Self.dependsOnWarning(
            service, "Service '\(service)' did not become healthy within \(retries) checks; starting dependents anyway.")
    }

    private func pollCompleted(name: String, service: String) async throws -> Warning? {
        let maxAttempts = 120
        for _ in 1...maxAttempts {
            let state = try await engine.state(name: name)
            if !state.running {
                switch state.exitCode {
                case 0:
                    return nil
                case let code?:
                    return Self.dependsOnWarning(service, "Service '\(service)' exited with code \(code).")
                case nil:
                    // Apple `container inspect` omits the exit status, so we can't confirm success.
                    return Self.dependsOnWarning(
                        service, "Service '\(service)' completed, but Apple container does not report its exit status — cannot confirm it exited 0.")
                }
            }
            try await sleep(1.0)
        }
        return Self.dependsOnWarning(
            service, "Service '\(service)' did not complete within \(maxAttempts) checks; starting dependents anyway.")
    }

    private static func dependsOnWarning(_ service: String, _ message: String) -> Warning {
        Warning(kind: .engineGap(.healthcheck), service: service, key: "depends_on", message: message, severity: .warning)
    }

    /// Turn a normalized healthcheck `test` into an exec argv. `nil` for NONE/empty.
    static func healthcheckCommand(_ test: [String]) -> [String]? {
        guard let directive = test.first else { return nil }
        switch directive.uppercased() {
        case "CMD": return test.count > 1 ? Array(test.dropFirst()) : nil
        case "CMD-SHELL": return test.count > 1 ? ["sh", "-c", test[1]] : nil
        default: return nil
        }
    }

    /// Parse a Go-style duration ("10s", "1m30s", "500ms", bare "2"=seconds) to seconds.
    static func parseDuration(_ raw: String?) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        func flush() -> Bool {
            guard !number.isEmpty, let value = Double(number) else { return false }
            switch unit {
            case "ns": total += value / 1_000_000_000
            case "us", "µs": total += value / 1_000_000
            case "ms": total += value / 1_000
            case "s", "": total += value
            case "m": total += value * 60
            case "h": total += value * 3600
            default: return false
            }
            number = ""; unit = ""
            return true
        }
        for ch in raw {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty, !flush() { return nil }
                number.append(ch)
            } else {
                unit.append(ch)
            }
        }
        return flush() ? total : nil
    }
}
