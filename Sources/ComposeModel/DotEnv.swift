import Foundation

/// Parses a `.env` file's contents into variables for interpolation.
///
/// Pure — the caller reads the file. Handles what Compose's own `.env` handling
/// does: `KEY=VALUE` lines, `#` comments, blank lines, an optional `export`
/// prefix, and quoted values (single quotes literal, double quotes with the usual
/// escapes). A line that is not an assignment is skipped rather than guessed at.
public enum DotEnv {

    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        // Split on unicode scalars: `\r\n` is a single `Character`, so splitting on
        // `"\n"` would never match a CRLF file and would swallow it whole.
        for rawLine in contents.unicodeScalars.split(
            omittingEmptySubsequences: false, whereSeparator: { CharacterSet.newlines.contains($0) }
        ) {
            var line = String(String.UnicodeScalarView(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }

            let (rawKey, rawValue) = splitKeyValue(line)
            guard let rawValue else { continue }  // not an assignment
            let key = rawKey.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = value(from: rawValue)
        }
        return values
    }

    private static func value(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // A quoted value ends at its closing quote; anything after it (a comment,
        // typically) is not part of the value.
        if let quote = trimmed.first, quote == "'" || quote == "\"" {
            let body = trimmed.dropFirst()
            if let close = closingQuote(quote, in: body) {
                let content = String(body[..<close])
                return quote == "\"" ? unescape(content) : content
            }
            // Unterminated quote: keep what is there rather than dropping the value.
            return String(body)
        }
        // Unquoted: ` #` starts a trailing comment, matching Compose.
        if let comment = trimmed.range(of: " #") {
            return String(trimmed[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// The closing quote's index, skipping one escaped by a backslash inside `"…"`.
    private static func closingQuote(_ quote: Character, in body: Substring) -> Substring.Index? {
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if quote == "\"", character == "\\" {
                index = body.index(index, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
                continue
            }
            if character == quote { return index }
            index = body.index(after: index)
        }
        return nil
    }

    private static func unescape(_ text: String) -> String {
        var output = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                output.append(character)
                continue
            }
            switch escaped {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "\\": output.append("\\")
            case "\"": output.append("\"")
            default: output.append("\\"); output.append(escaped)
            }
        }
        return output
    }
}
