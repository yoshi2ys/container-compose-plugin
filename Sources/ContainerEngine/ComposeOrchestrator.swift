import ComposeGraph
import ComposeModel
import ComposeTranslate
import Foundation

public enum OrchestratorError: Error, Sendable {
    case systemNotRunning
    case graph(GraphError)
    case blocking([Warning])
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
    /// (dependency order). Returns the collected warnings. Validates the whole
    /// project before mutating anything, so a blocking error starts nothing.
    @discardableResult
    public func up(
        project: ComposeProject,
        activeProfiles: Set<String> = [],
        options: TranslateOptions = TranslateOptions()
    ) async throws -> [Warning] {
        guard try await engine.systemRunning() else { throw OrchestratorError.systemNotRunning }

        let plan: StartupPlan
        switch ComposeGraph.startupPlan(project, activeProfiles: activeProfiles) {
        case .success(let value): plan = value
        case .failure(let error): throw OrchestratorError.graph(error)
        }

        // Inject the host gateway as HOST_GATEWAY (a `host.docker.internal` stand-in,
        // since Apple container has no service-name DNS). Best-effort; never blocks up.
        var options = options
        if options.hostGateway == nil {
            options.hostGateway = try? await engine.hostGateway()
        }

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

        // Start wave by wave. Recreate each container (force-remove any stale one with
        // the same name first) so `up` is idempotent and recovers from a partial prior
        // run; named volumes persist, so data is kept.
        for wave in plan.waves {
            for serviceName in wave {
                guard let service = project.services[serviceName] else { continue }
                // Emulate `depends_on` health/completion conditions (Apple container has
                // no native healthcheck): wait on each dependency before starting. Skip
                // dependencies not in the startup plan (e.g. excluded by an inactive
                // profile) — they are never started, so there is nothing to wait for.
                for dependency in service.dependsOn
                where dependency.condition != .started && started.contains(dependency.service) {
                    if let warning = try await awaitReadiness(dependency, in: project) {
                        warnings.append(warning)
                    }
                }
                if service.build != nil,
                    let build = ComposeTranslate.buildArgs(
                        serviceName: serviceName, project: project, baseDirectory: options.baseDirectory) {
                    try await engine.build(argv: build.argv)
                }
                if let argv = runArgsByService[serviceName] {
                    try? await engine.remove(name: containerName(project: project, service: serviceName), force: true)
                    _ = try await engine.run(argv: argv)
                }
            }
        }
        return warnings
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

    /// Stop and remove the stack's containers in reverse dependency order.
    /// Errors per container are ignored (already gone / never started).
    public func down(project: ComposeProject, activeProfiles: Set<String> = []) async throws {
        let order: [String]
        switch ComposeGraph.startupPlan(project, activeProfiles: activeProfiles) {
        case .success(let plan): order = plan.shutdownOrder
        case .failure: order = project.serviceNames.reversed()
        }
        for serviceName in order {
            let name = containerName(project: project, service: serviceName)
            try? await engine.stop(name: name, timeout: nil)
            try? await engine.remove(name: name, force: true)
        }
    }

    /// List containers (passthrough to `container list --all`).
    @discardableResult
    public func ps() async throws -> Int32 {
        try await engine.forward(argv: ["list", "--all"])
    }

    /// Stream logs for a service (or the first service) — passthrough to `container logs`.
    @discardableResult
    public func logs(project: ComposeProject, service: String?, follow: Bool, tail: Int?) async throws -> Int32 {
        guard let serviceName = service ?? project.serviceNames.first else { return 1 }
        var argv = ["logs"]
        if follow { argv += ["-f"] }
        if let tail { argv += ["-n", "\(tail)"] }
        argv += [containerName(project: project, service: serviceName)]
        return try await engine.forward(argv: argv)
    }

    private func containerName(project: ComposeProject, service: String) -> String {
        project.services[service]?.containerName ?? "\(project.name ?? "compose")-\(service)"
    }

    /// Start the BuildKit builder if it is down — `container build` hangs and times
    /// out without it. Idempotent (only starts when `builderRunning` reports false).
    private func ensureBuilderRunning() async throws {
        if !(try await engine.builderRunning()) { try await engine.startBuilder() }
    }

    // MARK: - readiness (depends_on conditions)

    /// Block until `dependency` satisfies its condition. Returns a warning (and proceeds)
    /// if it times out — `up` is best-effort and must never hang.
    private func awaitReadiness(_ dependency: Dependency, in project: ComposeProject) async throws -> Warning? {
        let name = containerName(project: project, service: dependency.service)
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
