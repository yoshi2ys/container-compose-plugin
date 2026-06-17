import ComposeModel

/// The order in which to bring a stack up and down, derived from `depends_on`.
public struct StartupPlan: Sendable, Equatable {
    /// Services grouped into dependency "waves"; each wave can launch in parallel,
    /// and every wave's dependencies are satisfied by earlier waves.
    public var waves: [[String]]
    /// Reverse topological order for shutdown (dependents stop before dependencies).
    public var shutdownOrder: [String]

    public init(waves: [[String]], shutdownOrder: [String]) {
        self.waves = waves
        self.shutdownOrder = shutdownOrder
    }
}

public enum GraphError: Error, Equatable, Sendable {
    /// `depends_on` references a service not defined anywhere in the file.
    case missingDependency(service: String, dependency: String)
    /// A dependency cycle; the associated names are the services still entangled.
    case cycle([String])
}

public enum ComposeGraph {
    /// Services that should run given the active profiles. A service with no
    /// `profiles` always runs; one with profiles runs only if at least one is active.
    public static func includedServices(_ project: ComposeProject, activeProfiles: Set<String>) -> Set<String> {
        Set(project.services.compactMap { name, svc in
            (svc.profiles.isEmpty || !Set(svc.profiles).isDisjoint(with: activeProfiles)) ? name : nil
        })
    }

    /// Compute the startup/shutdown plan via Kahn's algorithm.
    ///
    /// Edges to services excluded by profiles are dropped; edges to services that
    /// do not exist at all are a hard error.
    public static func startupPlan(
        _ project: ComposeProject,
        activeProfiles: Set<String> = []
    ) -> Result<StartupPlan, GraphError> {
        let included = includedServices(project, activeProfiles: activeProfiles)

        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]
        for service in included { indegree[service] = 0 }

        for service in included {
            guard let svc = project.services[service] else { continue }
            for dep in svc.dependsOn {
                guard project.services.keys.contains(dep.service) else {
                    return .failure(.missingDependency(service: service, dependency: dep.service))
                }
                guard included.contains(dep.service) else { continue } // excluded by profile
                indegree[service, default: 0] += 1
                dependents[dep.service, default: []].append(service)
            }
        }

        var remaining = included
        var waves: [[String]] = []
        while !remaining.isEmpty {
            let wave = remaining.filter { indegree[$0] == 0 }.sorted()
            guard !wave.isEmpty else {
                return .failure(.cycle(remaining.sorted()))
            }
            for node in wave {
                remaining.remove(node)
                for dependent in dependents[node, default: []] {
                    indegree[dependent, default: 0] -= 1
                }
            }
            waves.append(wave)
        }

        let shutdownOrder = Array(waves.flatMap { $0 }.reversed())
        return .success(StartupPlan(waves: waves, shutdownOrder: shutdownOrder))
    }
}
