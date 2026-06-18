import Foundation

/// A diagnostic produced while parsing or translating a compose file.
///
/// Lives in `ComposeModel` (the lowest layer) so both the parser (unsupported-key
/// detection) and the translator (Apple-container gap detection) can emit the same type.
public struct Warning: Sendable, Hashable {
    public enum Severity: Sendable, Hashable, Comparable {
        case info
        case warning
        case blocking
    }

    /// A feature that Docker Compose expresses but Apple `container` cannot honor.
    public enum EngineGap: Sendable, Hashable {
        case restart
        case healthcheck
        case serviceNameDNS
        case multiNetwork
        case readOnlyBindNonRoot
        case privilegedPort
        case tmpfsSize
        case bindFileNotDirectory
    }

    public enum Kind: Sendable, Hashable {
        /// A key with no Apple-container equivalent; ignored.
        case unsupportedKey
        /// A value form we cannot represent (e.g. a port range).
        case unsupportedValue
        /// A known runtime gap; the message explains how it is handled.
        case engineGap(EngineGap)
        /// We worked around a limitation; the string describes how.
        case emulated(String)
    }

    public var kind: Kind
    public var service: String?
    public var key: String?
    public var message: String
    public var severity: Severity

    public init(kind: Kind, service: String? = nil, key: String? = nil, message: String, severity: Severity) {
        self.kind = kind
        self.service = service
        self.key = key
        self.message = message
        self.severity = severity
    }
}

extension Array where Element == Warning {
    /// Stable ordering: blocking first, then by service then key.
    public func sortedForDisplay() -> [Warning] {
        sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if (lhs.service ?? "") != (rhs.service ?? "") { return (lhs.service ?? "") < (rhs.service ?? "") }
            return (lhs.key ?? "") < (rhs.key ?? "")
        }
    }
}
