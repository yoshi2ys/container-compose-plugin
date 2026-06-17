import Foundation

/// A YAML scalar coerced to a string. Compose values are routinely unquoted
/// numbers/bools (`environment: { DEBUG: true, PORT: 8080 }`), so we decode the
/// scalar in its natural type and expose a `stringValue` for the CLI.
public enum YAMLScalar: Decodable, Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    /// `nil` only for `.null` (a compose env entry with no value = inherit from host).
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        }
    }
}

/// Splits a `"KEY=VALUE"` item into its key and value at the first `=`.
/// A bare `"KEY"` (no `=`) yields `nil` value, distinguishing it from `"KEY="`.
func splitKeyValue(_ item: String) -> (key: String, value: String?) {
    guard let eq = item.firstIndex(of: "=") else { return (item, nil) }
    return (String(item[..<eq]), String(item[item.index(after: eq)...]))
}

/// A `CodingKey` for iterating arbitrary mapping keys (used to decode maps whose
/// values may be `null`, which `[String: T]` cannot represent for non-optional `T`).
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// Types that can supply a default instance when a mapping value is `null`
/// (e.g. `networks: { default: }` means "the default network").
protocol DefaultConstructible {
    init()
}

/// Decodes a `[String: Value]` mapping that may contain `null` values, substituting
/// `Value()` for each null entry while preserving the key.
struct NullableMap<Value: Decodable & DefaultConstructible>: Decodable {
    let values: [String: Value]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var out: [String: Value] = [:]
        for key in c.allKeys {
            if let v = try c.decodeIfPresent(Value.self, forKey: key) {
                out[key.stringValue] = v
            } else {
                out[key.stringValue] = Value()
            }
        }
        values = out
    }
}
