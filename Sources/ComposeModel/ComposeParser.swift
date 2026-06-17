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

public enum ComposeParser {
    /// Top-level compose keys we recognize (others produce an info warning).
    static let knownTopLevelKeys: Set<String> = [
        "name", "services", "networks", "volumes", "version",
        "configs", "secrets", "include",
    ]

    /// Parse a compose YAML document into a typed project plus a list of
    /// warnings for keys we do not support (never silently dropped).
    ///
    /// - Parameter projectNameFallback: used as the project name when the file
    ///   has no top-level `name:` (Compose derives it from the directory name).
    public static func parse(_ yaml: String, projectNameFallback: String) throws -> ParseResult {
        var project = try YAMLDecoder().decode(ComposeProject.self, from: yaml)
        if (project.name ?? "").isEmpty {
            project.name = sanitizeProjectName(projectNameFallback)
        }

        let warnings = collectUnsupportedKeyWarnings(yaml: yaml, project: &project)
        return ParseResult(project: project, warnings: warnings.sortedForDisplay())
    }

    /// Walk the raw YAML tree and diff each mapping's keys against the keys we
    /// model, recording the leftovers as warnings and on each `Service`.
    private static func collectUnsupportedKeyWarnings(yaml: String, project: inout ComposeProject) -> [Warning] {
        guard let raw = (try? Yams.load(yaml: yaml)) as? [String: Any] else { return [] }
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
