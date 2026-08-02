import Foundation
import Yams

public struct ParseResult: Sendable {
    public let project: ComposeProject
    public let warnings: [Warning]
    public init(project: ComposeProject, warnings: [Warning]) {
        self.project = project
        self.warnings = warnings
    }
}

/// An interpolation that could not be resolved, with the compose key it came from.
public struct InterpolationFailure: Error, Equatable, CustomStringConvertible {
    /// Dotted path to the offending value, e.g. `services.db.environment.PASSWORD`.
    public let path: String
    public let reason: InterpolationError

    public init(path: String, reason: InterpolationError) {
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(path): \(reason)" }
}

/// A compose file this parser will not accept.
public enum ComposeParseError: Error, Equatable, CustomStringConvertible {
    /// No YAML document at all — an empty or comment-only file, which is what a
    /// truncated write leaves behind.
    case emptyDocument

    public var description: String {
        switch self {
        case .emptyDocument: return "the compose file has no content"
        }
    }
}

public enum ComposeParser {
    /// Top-level compose keys we recognize (others produce an info warning).
    static let knownTopLevelKeys: Set<String> = [
        "name", "services", "networks", "volumes", "version",
        "configs", "secrets", "include",
    ]

    /// Parse a compose YAML document into a typed project plus a list of
    /// warnings for keys we do not support (never silently dropped).
    ///
    /// The document is composed into a node tree **once**; variable interpolation,
    /// decoding and the unsupported-key diff all read that same tree, so what the
    /// model sees and what the key diff sees cannot drift apart.
    ///
    /// - Parameters:
    ///   - projectNameFallback: used as the project name when the file has no
    ///     top-level `name:` (Compose derives it from the directory name).
    ///   - environment: variable lookup for `${…}` interpolation. Injected, so the
    ///     process environment and `.env` stay outside this layer. The default
    ///     resolves nothing, which is Compose's behavior for an unset variable.
    public static func parse(
        _ yaml: String,
        projectNameFallback: String,
        environment: (String) -> String? = { _ in nil }
    ) throws -> ParseResult {
        try composing(yaml, environment: environment) { interpolated, unset in
            var project = try YAMLDecoder().decode(ComposeProject.self, from: interpolated)
            if (project.name ?? "").isEmpty {
                project.name = sanitizeProjectName(projectNameFallback)
            }

            var warnings = collectUnsupportedKeyWarnings(
                raw: interpolated.any as? [String: Any], project: &project)
            warnings += unsetVariableWarnings(unset)
            return ParseResult(project: project, warnings: warnings.sortedForDisplay())
        }
    }

    /// The compose file as YAML with every `${…}` substituted — what `compose config`
    /// prints, and what the rest of the pipeline actually reads.
    /// `projectNameFallback` is written into the output when the file has no
    /// `name:`, so the document shows the project name the other commands use.
    public static func interpolatedDocument(
        _ yaml: String,
        projectNameFallback: String,
        environment: (String) -> String? = { _ in nil }
    ) throws -> String {
        try composing(yaml, environment: environment) { interpolated, _ in
            var root = interpolated
            if let mapping = root.mapping, (mapping["name"]?.string ?? "").isEmpty {
                // Prepended, so the document reads the way a compose file is written.
                let pairs: [(Node, Node)] = [(Node("name"), Node(sanitizeProjectName(projectNameFallback)))]
                    + mapping.map { ($0, $1) }
                root = .mapping(Node.Mapping(pairs, mapping.tag, mapping.style, mapping.mark, mapping.anchor))
            }
            return try Yams.serialize(node: root)
        }
    }

    /// Composes the document once, interpolates it, and hands the result to `body`.
    private static func composing<T>(
        _ yaml: String,
        environment: (String) -> String?,
        _ body: (Node, [String]) throws -> T
    ) throws -> T {
        // `Resolver([.merge])` is what `YAMLDecoder` uses internally: scalars keep
        // their string form and `Decodable` does the coercion. Resolving tags here
        // instead would change how values decode.
        //
        // Spelled out rather than via `Yams.compose(yaml:)` so the parser stays alive
        // for the whole walk: nodes hold their anchors weakly, and `Node.any` (used
        // for the key diff) constructs from them.
        let parser = try Yams.Parser(yaml: yaml, resolver: Resolver.basic.appending(.merge))
        return try withExtendedLifetime(parser) {
            guard let root = try parser.singleRoot() else { throw ComposeParseError.emptyDocument }
            var unset: [String] = []
            let interpolated = try interpolate(root, path: "", environment: environment, unset: &unset)
            return try body(interpolated, unset)
        }
    }

    // MARK: - interpolation

    /// Rewrites every scalar in the tree. Walking the nodes rather than the decoded
    /// model is what makes this complete: a new `Service` property cannot be missed,
    /// because interpolation never looks at the model at all.
    private static func interpolate(
        _ node: Node, path: String, environment: (String) -> String?, unset: inout [String]
    ) throws -> Node {
        switch node {
        case .scalar(let scalar):
            // Quoting style is carried over untouched; only the text changes.
            switch Interpolator.expand(scalar.string, env: environment) {
            case .failure(let reason):
                throw InterpolationFailure(path: path.isEmpty ? "<root>" : path, reason: reason)
            case .success(let result):
                unset.append(contentsOf: result.unset)
                var rewritten = scalar
                rewritten.string = result.value
                return .scalar(rewritten)
            }

        case .mapping(let mapping):
            var pairs: [(Node, Node)] = []
            for (key, value) in mapping {
                let child = path.isEmpty ? (key.string ?? "") : "\(path).\(key.string ?? "")"
                pairs.append((
                    try interpolate(key, path: child, environment: environment, unset: &unset),
                    try interpolate(value, path: child, environment: environment, unset: &unset)
                ))
            }
            return .mapping(Node.Mapping(pairs, mapping.tag, mapping.style, mapping.mark, mapping.anchor))

        case .sequence(let sequence):
            let nodes = try sequence.indices.map { index in
                try interpolate(
                    sequence[index], path: "\(path)[\(index)]", environment: environment,
                    unset: &unset)
            }
            return .sequence(
                Node.Sequence(nodes, sequence.tag, sequence.style, sequence.mark, sequence.anchor))

        case .alias:
            // The parser expands aliases into the tree, so this only appears with a
            // dereferencing strategy we do not use. Left as-is rather than guessed at.
            return node
        }
    }

    private static func unsetVariableWarnings(_ unset: [String]) -> [Warning] {
        Set(unset).sorted().map { name in
            Warning(
                kind: .unsetVariable, key: name,
                message: "The '\(name)' variable is not set; substituted an empty string.",
                severity: .warning)
        }
    }

    // MARK: - unsupported keys

    /// Diff each mapping's keys against the keys we model, recording the leftovers
    /// as warnings and on each `Service`.
    ///
    /// Reads `Node.any` rather than walking the node tree: that conversion goes
    /// through Yams' constructor, which resolves YAML merge keys (`<<: *base`).
    /// Walking the raw pairs instead would report `<<` as an unsupported key and
    /// miss the merged-in ones — the decoder resolves merges, so the diff has to too.
    private static func collectUnsupportedKeyWarnings(
        raw: [String: Any]?, project: inout ComposeProject
    ) -> [Warning] {
        guard let raw else { return [] }
        var warnings: [Warning] = []

        for key in raw.keys where !knownTopLevelKeys.contains(key) {
            warnings.append(Warning(
                kind: .unsupportedKey, key: key,
                message: "Top-level key '\(key)' is not supported and will be ignored.",
                severity: .info))
        }

        guard let rawServices = raw["services"] as? [String: Any] else { return warnings }
        for (name, value) in rawServices {
            guard let svc = value as? [String: Any] else { continue }
            let unknown = svc.keys.filter { !Service.knownKeys.contains($0) }.sorted()
            guard !unknown.isEmpty else { continue }
            project.services[name]?.unknownKeys = unknown
            for key in unknown {
                warnings.append(Warning(
                    kind: .unsupportedKey, service: name, key: key,
                    message: "Key '\(key)' on service '\(name)' is not supported and will be ignored.",
                    severity: .warning))
            }
        }
        return warnings
    }

    /// Compose project names are lowercased and restricted to `[a-z0-9_-]`.
    static func sanitizeProjectName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") ? ch : "-"
        }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "compose" : result
    }
}
