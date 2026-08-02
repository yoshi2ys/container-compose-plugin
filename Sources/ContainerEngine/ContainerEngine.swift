import ComposeTranslate
import Foundation

/// A `container` operation failed (non-zero exit). Carries enough to reproduce
/// the failure in a terminal.
public struct EngineError: Error, Sendable, Equatable {
    public let argv: [String]
    public let exitCode: Int32
    public let stderr: String

    public init(argv: [String], exitCode: Int32, stderr: String) {
        self.argv = argv
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// A container's run state. `exitCode` is `nil` when unknown — Apple `container
/// inspect` reports `state` but not the exit status of a stopped container.
public struct ContainerState: Sendable, Equatable {
    public let running: Bool
    public let exitCode: Int32?
    public init(running: Bool, exitCode: Int32? = nil) {
        self.running = running
        self.exitCode = exitCode
    }
}

/// A host port published by a container, as reported by `container list`.
public struct PublishedPort: Sendable, Equatable, CustomStringConvertible {
    public let hostAddress: String?
    public let hostPort: Int
    public let containerPort: Int
    public let proto: String?

    public init(hostAddress: String? = nil, hostPort: Int, containerPort: Int, proto: String? = nil) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    /// Docker-style rendering, e.g. `0.0.0.0:8080->80/tcp`.
    public var description: String {
        let host = hostAddress.map { "\($0):" } ?? ""
        let suffix = proto.map { "/\($0)" } ?? ""
        return "\(host)\(hostPort)->\(containerPort)\(suffix)"
    }
}

/// One container as listed by the engine. `labels` is what makes this useful:
/// it carries `com.composeforcontainer.project` / `.service` for the containers
/// this plugin created, which is how a stack is identified — the name is only a
/// display and DNS attribute.
public struct ContainerSummary: Sendable, Equatable {
    /// The container's id, which for Apple `container` is also its name.
    public let id: String
    public let image: String
    public let state: String
    public let labels: [String: String]
    public let ports: [PublishedPort]

    public init(
        id: String, image: String, state: String,
        labels: [String: String] = [:], ports: [PublishedPort] = []
    ) {
        self.id = id
        self.image = image
        self.state = state
        self.labels = labels
        self.ports = ports
    }

    /// `container` reports `running` for a live container; anything else (stopped,
    /// created, …) is not running.
    public var isRunning: Bool { state.lowercased() == "running" }

    /// The compose project that owns this container, `nil` if it carries no
    /// compose labels (created by hand, or by the engine itself).
    public var composeProject: String? { labels[ComposeLabels.project] }
    /// The service this container implements, within `composeProject`.
    public var composeService: String? { labels[ComposeLabels.service] }
}

/// Semantic operations against the container runtime. The CLI implementation
/// shells out to `container`; the protocol exists so the orchestrator can be
/// tested against a mock (and a future XPC implementation can slot in).
public protocol ContainerEngine: Sendable {
    /// Whether `container system` services are up (required before any container op).
    func systemRunning() async throws -> Bool
    /// Whether the image builder (BuildKit) is running — required before any `build`.
    func builderRunning() async throws -> Bool
    /// Start the image builder (idempotent; only called when `builderRunning` is false).
    func startBuilder() async throws
    /// The host's address as seen from inside containers (the default network's IPv4
    /// gateway), or `nil`. Injected into containers as `HOST_GATEWAY`.
    func hostGateway() async throws -> String?
    /// Run a detached container from a pre-built `container run …` argv; returns the id/stdout.
    func run(argv: [String]) async throws -> String
    /// Build an image from a pre-built `container build …` argv.
    func build(argv: [String]) async throws
    /// Create a network from a pre-built `container network create …` argv.
    func createNetwork(argv: [String]) async throws
    /// Create a volume from a pre-built `container volume create …` argv.
    func createVolume(argv: [String]) async throws
    /// Run a command inside a running container; returns its exit code (no throw on non-zero).
    /// Used to poll a `healthcheck` for `depends_on: service_healthy`.
    func exec(name: String, argv: [String]) async throws -> Int32
    /// A container's current run state (for `depends_on: service_completed_successfully`).
    func state(name: String) async throws -> ContainerState
    /// Stop a container by name.
    func stop(name: String, timeout: Int?) async throws
    /// Remove a container by name.
    func remove(name: String, force: Bool) async throws
    /// Run a `container` subcommand with inherited stdio (e.g. `ps`, `logs`); returns exit code.
    func forward(argv: [String]) async throws -> Int32
    /// Every container the engine knows about, running or not, with its labels —
    /// the source for identifying a project's containers.
    func listContainers() async throws -> [ContainerSummary]
}
