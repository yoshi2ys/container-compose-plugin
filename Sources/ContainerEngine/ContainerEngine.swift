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
}
