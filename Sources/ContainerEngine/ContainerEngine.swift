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

/// Semantic operations against the container runtime. The CLI implementation
/// shells out to `container`; the protocol exists so the orchestrator can be
/// tested against a mock (and a future XPC implementation can slot in).
public protocol ContainerEngine: Sendable {
    /// Whether `container system` services are up (required before any container op).
    func systemRunning() async throws -> Bool
    /// Run a detached container from a pre-built `container run …` argv; returns the id/stdout.
    func run(argv: [String]) async throws -> String
    /// Build an image from a pre-built `container build …` argv.
    func build(argv: [String]) async throws
    /// Create a network from a pre-built `container network create …` argv.
    func createNetwork(argv: [String]) async throws
    /// Create a volume from a pre-built `container volume create …` argv.
    func createVolume(argv: [String]) async throws
    /// Stop a container by name.
    func stop(name: String, timeout: Int?) async throws
    /// Remove a container by name.
    func remove(name: String, force: Bool) async throws
    /// Run a `container` subcommand with inherited stdio (e.g. `ps`, `logs`); returns exit code.
    func forward(argv: [String]) async throws -> Int32
}
