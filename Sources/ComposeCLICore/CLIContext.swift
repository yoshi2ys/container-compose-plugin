import ComposeTranslate
import ContainerEngine
import Foundation

/// Everything `ComposeCLI` needs from the outside world: argv, the filesystem,
/// the two output streams, and the engine to drive.
///
/// The CLI is an `executableTarget` and cannot be linked into a test target, so
/// the logic lives here in a library and takes its environment through this seam.
/// `live` wires the real process; tests substitute closures.
public struct CLIContext: Sendable {
    public var arguments: [String]
    public var currentDirectory: String
    /// stdout sink; the string is written verbatim (callers add their own newline).
    public var write: @Sendable (String) -> Void
    /// stderr sink.
    public var writeError: @Sendable (String) -> Void
    /// What kind of entry is at a path (drives compose-file lookup and bind preflight).
    public var pathKind: @Sendable (String) -> PathKind
    public var readFile: @Sendable (String) throws -> String
    public var makeEngine: @Sendable () -> any ContainerEngine
    /// The process environment, the first source for `${…}` interpolation.
    public var environment: [String: String]

    public init(
        arguments: [String],
        currentDirectory: String,
        write: @escaping @Sendable (String) -> Void,
        writeError: @escaping @Sendable (String) -> Void,
        pathKind: @escaping @Sendable (String) -> PathKind,
        readFile: @escaping @Sendable (String) throws -> String,
        makeEngine: @escaping @Sendable () -> any ContainerEngine,
        environment: [String: String] = [:]
    ) {
        self.arguments = arguments
        self.currentDirectory = currentDirectory
        self.write = write
        self.writeError = writeError
        self.pathKind = pathKind
        self.readFile = readFile
        self.makeEngine = makeEngine
        self.environment = environment
    }

    /// The real process environment: `FileManager`, the standard streams, and the
    /// `container`-CLI-backed engine.
    public static func live(arguments: [String]) -> CLIContext {
        CLIContext(
            arguments: arguments,
            currentDirectory: FileManager.default.currentDirectoryPath,
            write: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeError: { FileHandle.standardError.write(Data($0.utf8)) },
            pathKind: { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                else { return .missing }
                return isDirectory.boolValue ? .directory : .file
            },
            readFile: { try String(contentsOfFile: $0, encoding: .utf8) },
            makeEngine: { CLIContainerEngine() },
            environment: ProcessInfo.processInfo.environment
        )
    }
}

/// A CLI-layer failure with a message already fit for stderr.
public struct CLIError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
