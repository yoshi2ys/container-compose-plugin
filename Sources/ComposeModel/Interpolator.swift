import Foundation

/// A `${…}` reference this interpolator will not guess at.
public enum InterpolationError: Error, Equatable, CustomStringConvertible {
    /// `${VAR:?message}` / `${VAR?message}` with no value.
    case required(variable: String, message: String?)
    /// A `${` with no closing brace.
    case unterminated(String)
    /// `${A:-${B}}` or `${A:-$B}`. Compose expands the default; this does not, and
    /// substituting it verbatim would put a literal `$B` in the container.
    case nested(String)
    /// A modifier outside the supported set, e.g. `${VAR:+x}`.
    case unsupportedModifier(reference: String)
    /// `${}`, or a name that is not `[A-Za-z_][A-Za-z0-9_]*`.
    case invalidName(reference: String)

    public var description: String {
        switch self {
        case .required(let variable, let message):
            return message.map { "required variable '\(variable)' is missing: \($0)" }
                ?? "required variable '\(variable)' is missing"
        case .unterminated(let reference):
            return "'\(reference)' is missing its closing brace"
        case .nested(let reference):
            return "'\(reference)' references a variable inside a default; that is not "
                + "supported — give the default a literal value"
        case .unsupportedModifier(let reference):
            return "'\(reference)' uses a modifier this plugin does not support "
                + "(supported: ${VAR}, ${VAR:-default}, ${VAR-default}, ${VAR:?error}, ${VAR?error})"
        case .invalidName(let reference):
            return "'\(reference)' is not a valid variable reference"
        }
    }
}

public struct Interpolation: Equatable {
    public let value: String
    /// Variables with no value and no default. Compose substitutes an empty string
    /// and says so; the caller turns these into warnings.
    public let unset: [String]

    public init(value: String, unset: [String] = []) {
        self.value = value
        self.unset = unset
    }
}

/// Compose variable interpolation.
///
/// Pure: the caller supplies `env`, so the process environment and `.env` stay in
/// the CLI layer. Supported forms are `$VAR`, `${VAR}`, `${VAR:-default}`,
/// `${VAR-default}`, `${VAR:?error}`, `${VAR?error}` and `$$` for a literal `$`.
/// Anything else is an error rather than a guess.
public enum Interpolator {

    public static func expand(
        _ template: String, env: (String) -> String?
    ) -> Result<Interpolation, InterpolationError> {
        guard template.contains("$") else { return .success(Interpolation(value: template)) }

        var output = ""
        var unset: [String] = []
        var index = template.startIndex

        while index < template.endIndex {
            let character = template[index]
            guard character == "$" else {
                output.append(character)
                index = template.index(after: index)
                continue
            }

            let afterDollar = template.index(after: index)
            guard afterDollar < template.endIndex else {
                // A trailing `$` is a literal `$`, as in Compose.
                output.append("$")
                index = afterDollar
                continue
            }

            switch template[afterDollar] {
            case "$":
                output.append("$")
                index = template.index(after: afterDollar)

            case "{":
                let bodyStart = template.index(after: afterDollar)
                guard let close = template[bodyStart...].firstIndex(of: "}") else {
                    return .failure(.unterminated(String(template[index...])))
                }
                switch substitute(body: String(template[bodyStart..<close]), env: env) {
                case .failure(let error): return .failure(error)
                case .success(let resolved):
                    output.append(resolved.value)
                    unset.append(contentsOf: resolved.unset)
                }
                index = template.index(after: close)

            default:
                let (name, next) = bareName(template, from: afterDollar)
                guard !name.isEmpty else {
                    // `$` before punctuation is a literal `$`.
                    output.append("$")
                    index = afterDollar
                    continue
                }
                let value = env(name)
                if value == nil { unset.append(name) }
                output.append(value ?? "")
                index = next
            }
        }
        return .success(Interpolation(value: output, unset: unset))
    }

    // MARK: - pieces

    /// The inside of a `${…}`. The two axes are whether the modifier is prefixed
    /// with `:` (which makes a set-but-empty value count as missing) and whether it
    /// is `-` (substitute a default) or `?` (fail).
    private static func substitute(
        body: String, env: (String) -> String?
    ) -> Result<Interpolation, InterpolationError> {
        let reference = "${\(body)}"
        var (name, rest) = splitName(body)
        guard isValidName(name) else { return .failure(.invalidName(reference: reference)) }
        // A default is taken verbatim, so a variable inside one would reach the
        // container unexpanded. Refuse rather than substitute something the author
        // did not write. Covers both `${A:-${B}}` and `${A:-$B}`.
        guard !rest.contains("$") else { return .failure(.nested(reference)) }

        let value = env(name)
        let colonForm = rest.hasPrefix(":")
        if colonForm { rest.removeFirst() }
        let satisfied = colonForm ? !(value ?? "").isEmpty : value != nil

        switch rest.first {
        case nil:
            guard !colonForm else { return .failure(.unsupportedModifier(reference: reference)) }
            return .success(Interpolation(value: value ?? "", unset: value == nil ? [name] : []))
        case "-":
            return .success(Interpolation(value: satisfied ? value! : String(rest.dropFirst())))
        case "?":
            guard satisfied else {
                return .failure(.required(variable: name, message: message(String(rest.dropFirst()))))
            }
            return .success(Interpolation(value: value!))
        default:
            return .failure(.unsupportedModifier(reference: reference))
        }
    }

    private static func message(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// Splits `NAME:-rest` into `("NAME", ":-rest")`.
    private static func splitName(_ body: String) -> (name: String, rest: String) {
        let end = body.firstIndex { !isNameCharacter($0) } ?? body.endIndex
        return (String(body[..<end]), String(body[end...]))
    }

    /// The `$NAME` form: reads name characters from `start`.
    private static func bareName(
        _ template: String, from start: String.Index
    ) -> (name: String, next: String.Index) {
        guard let first = template[start...].first, isNameStart(first) else { return ("", start) }
        let end = template[start...].firstIndex { !isNameCharacter($0) } ?? template.endIndex
        return (String(template[start..<end]), end)
    }

    // Environment variable names are ASCII; `Character.isLetter` alone would accept
    // 'é' and read a name the shell never could.
    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    private static func isNameStart(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character == "_")
    }

    // `splitName` stops at the first non-name character, so only the first one
    // still needs checking.
    private static func isValidName(_ name: String) -> Bool {
        name.first.map(isNameStart) ?? false
    }
}
