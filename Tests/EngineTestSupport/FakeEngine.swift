import ComposeTranslate
import ContainerEngine

/// A compose-labelled container, as the engine would report it.
public func composeContainer(
    project: String, service: String, name: String? = nil,
    state: String = "running", image: String = "x", ports: [PublishedPort] = []
) -> ContainerSummary {
    ContainerSummary(
        id: name ?? "\(project)-\(service)", image: image, state: state,
        labels: [ComposeLabels.project: project, ComposeLabels.service: service],
        ports: ports)
}

/// The engine seam for tests: records the operations it is asked to perform, and
/// keeps a container store so label lookups (`ps`, `down`, the recreate guard,
/// `up`'s post-start check) see a plausible engine state.
///
/// One type shared by both test targets. The `ContainerEngine` protocol grows
/// with each phase, and a second copy of this would mean implementing every new
/// method twice.
public actor FakeEngine: ContainerEngine {
    /// Every mutating call, in order, as `"<verb>:<subject>"`. Reads are not
    /// recorded — every command issues them, and they would drown the signal.
    public private(set) var operations: [String] = []
    /// Full argv of every `build`, for asserting flags like `--no-cache`.
    public private(set) var buildInvocations: [[String]] = []
    /// Full argv of every `run`, for asserting translated values.
    public private(set) var runInvocations: [[String]] = []

    private var running: Bool
    private var builderUp: Bool
    private let forwardExit: Int32
    private var containers: [ContainerSummary]
    /// Services whose container registers as stopped rather than running.
    private var exiting: Set<String>
    /// Consumed one per `exec` / `state` call; empty falls back to success/stopped.
    private var execResults: [Int32] = []
    private var states: [ContainerState] = []

    public init(
        running: Bool = true,
        builderUp: Bool = true,
        forwardExit: Int32 = 0,
        containers: [ContainerSummary] = [],
        exiting: Set<String> = []
    ) {
        self.running = running
        self.builderUp = builderUp
        self.forwardExit = forwardExit
        self.containers = containers
        self.exiting = exiting
    }

    public func setRunning(_ value: Bool) { running = value }
    public func setBuilderUp(_ value: Bool) { builderUp = value }
    public func setContainers(_ value: [ContainerSummary]) { containers = value }
    public func setExiting(_ value: Set<String>) { exiting = value }
    public func setExecResults(_ value: [Int32]) { execResults = value }
    public func setStates(_ value: [ContainerState]) { states = value }

    // MARK: - ContainerEngine

    public func systemRunning() async throws -> Bool { running }
    public func builderRunning() async throws -> Bool { builderUp }
    public func startBuilder() async throws { operations.append("builderstart") }
    public func hostGateway() async throws -> String? { nil }
    public func listContainers() async throws -> [ContainerSummary] { containers }

    public func run(argv: [String]) async throws -> String {
        let name = value(after: "--name", in: argv) ?? "?"
        operations.append("run:\(name)")
        runInvocations.append(argv)
        let labels = labels(in: argv)
        containers.append(ContainerSummary(
            id: name, image: argv.last ?? "",
            state: exiting.contains(labels[ComposeLabels.service] ?? "") ? "stopped" : "running",
            labels: labels))
        return "id"
    }

    public func build(argv: [String]) async throws {
        buildInvocations.append(argv)
        operations.append("build:\(value(after: "-t", in: argv) ?? "?")")
    }

    public func createNetwork(argv: [String]) async throws {
        operations.append("net:\(argv.count > 2 ? argv[2] : "?")")
    }

    public func createVolume(argv: [String]) async throws {
        operations.append("vol:\(argv.count > 2 ? argv[2] : "?")")
    }

    public func exec(name: String, argv: [String]) async throws -> Int32 {
        operations.append("exec:\(name)")
        return execResults.isEmpty ? 0 : execResults.removeFirst()
    }

    public func state(name: String) async throws -> ContainerState {
        operations.append("state:\(name)")
        return states.isEmpty ? ContainerState(running: false) : states.removeFirst()
    }

    public func stop(name: String, timeout: Int?) async throws {
        operations.append("stop:\(name)")
        setState(of: name, to: "stopped")
    }

    public func start(name: String) async throws {
        operations.append("start:\(name)")
        setState(of: name, to: "running")
    }

    private func setState(of name: String, to state: String) {
        guard let index = containers.firstIndex(where: { $0.id == name }) else { return }
        let existing = containers[index]
        containers[index] = ContainerSummary(
            id: existing.id, image: existing.image, state: state,
            labels: existing.labels, ports: existing.ports)
    }

    public func remove(name: String, force: Bool) async throws {
        operations.append("rm:\(name)")
        containers.removeAll { $0.id == name }
    }

    public func forward(argv: [String]) async throws -> Int32 {
        operations.append("forward:\(argv.joined(separator: " "))")
        return forwardExit
    }

    // MARK: - argv reading

    private func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    private func labels(in argv: [String]) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, argument) in argv.enumerated() where argument == "--label" && index + 1 < argv.count {
            let pair = argv[index + 1]
            guard let separator = pair.firstIndex(of: "=") else { continue }
            labels[String(pair[..<separator])] = String(pair[pair.index(after: separator)...])
        }
        return labels
    }
}
