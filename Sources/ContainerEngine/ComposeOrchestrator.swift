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

    public init(engine: any ContainerEngine) {
        self.engine = engine
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

        // Translate everything first; refuse to start if anything is blocking.
        var warnings: [Warning] = []
        var runArgsByService: [String: [String]] = [:]
        for serviceName in plan.waves.flatMap({ $0 }) {
            let result = ComposeTranslate.runArgs(serviceName: serviceName, project: project, options: options)
            warnings.append(contentsOf: result.warnings)
            runArgsByService[serviceName] = result.argv
        }
        let blocking = warnings.filter { $0.severity == .blocking }
        guard blocking.isEmpty else { throw OrchestratorError.blocking(blocking) }

        // Prerequisites (idempotent; "already exists" is fine to ignore).
        for prerequisite in ComposeTranslate.prerequisites(project) {
            switch prerequisite {
            case .network(_, let argv): try? await engine.createNetwork(argv: argv)
            case .volume(_, let argv): try? await engine.createVolume(argv: argv)
            }
        }

        // Start wave by wave. `container run -d` returns once started, which is the
        // only readiness signal Apple container offers (no healthcheck).
        for wave in plan.waves {
            for serviceName in wave {
                guard let service = project.services[serviceName] else { continue }
                if service.build != nil,
                    let build = ComposeTranslate.buildArgs(serviceName: serviceName, project: project) {
                    try await engine.build(argv: build.argv)
                }
                if let argv = runArgsByService[serviceName] {
                    _ = try await engine.run(argv: argv)
                }
            }
        }
        return warnings
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
}
