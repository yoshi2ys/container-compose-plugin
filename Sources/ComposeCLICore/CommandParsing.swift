import Foundation

/// The subcommands `container compose` accepts. Declaration order is the order
/// they appear in `--help`.
enum Command: String, CaseIterable {
    case up, down, build, ps, logs

    /// What this command takes and which options it accepts.
    ///
    /// An exhaustive `switch`, so a new command cannot compile without declaring
    /// one — parsing, validation and `--help` all read from here, and none of the
    /// three can describe a command the others do not.
    var spec: SubcommandSpec {
        switch self {
        case .up:
            return SubcommandSpec(
                summary: "Create and start the stack (dependency order)",
                discussion: """
                    Starts every service the active profiles include, in dependency order.
                    Each container is recreated, so a re-run recovers from a partial start;
                    named volumes persist.
                    """,
                options: [],
                positionals: .none(
                    hint: "`up` always starts the whole stack; starting a subset is not supported yet. "
                        + "Use `--profile <name>` to select a profile."))
        case .down:
            return SubcommandSpec(
                summary: "Stop and remove the stack (reverse order)",
                discussion: """
                    Stops and removes the project's containers in reverse dependency order.
                    Networks and named volumes are left in place.
                    """,
                options: [],
                positionals: .none(
                    hint: "`down` always removes the whole stack; removing a subset is not supported yet."))
        case .build:
            return SubcommandSpec(
                summary: "Build images for services with a build: section",
                discussion: """
                    Builds every service that declares `build:`, or only the named ones.
                    Profiles do not affect `build`.
                    """,
                options: [.noCache],
                positionals: .any(name: "service"))
        case .ps:
            return SubcommandSpec(
                summary: "List the stack's containers",
                discussion: "Lists the containers belonging to this project.",
                options: [],
                positionals: .none(hint: "`ps` takes no arguments."))
        case .logs:
            return SubcommandSpec(
                summary: "Show logs",
                discussion: "Shows the log of one service (the first one, when none is named).",
                options: [.follow, .tail],
                positionals: .atMostOne(name: "service"))
        }
    }

    /// The command with its operand syntax, e.g. `build [service...]`.
    var synopsis: String {
        switch spec.positionals {
        case .none: return rawValue
        case .atMostOne(let name): return "\(rawValue) [\(name)]"
        case .any(let name): return "\(rawValue) [\(name)...]"
        }
    }
}

/// The static description of one subcommand.
struct SubcommandSpec {
    let summary: String
    let discussion: String
    let options: [CommandOption]
    let positionals: PositionalRule
}

/// An option that belongs to particular subcommands. The global options
/// (`-f`/`--file`, `--profile`, `-h`/`--help`) are accepted everywhere and are
/// handled separately.
enum CommandOption: String, CaseIterable {
    case follow = "--follow"
    case tail = "--tail"
    case noCache = "--no-cache"

    /// How the option is written in help, value placeholder included.
    var usageLabel: String {
        switch self {
        case .tail: return "--tail <n>"
        case .follow, .noCache: return rawValue
        }
    }

    var summary: String {
        switch self {
        case .follow: return "Stream new log lines as they arrive"
        case .tail: return "Show only the last <n> lines"
        case .noCache: return "Build without the builder's layer cache"
        }
    }
}

/// What a subcommand does with bare words after its name.
enum PositionalRule: Equatable {
    /// None accepted; `hint` says what to do instead.
    case none(hint: String)
    case atMostOne(name: String)
    case any(name: String)
}

/// A fully parsed and validated command line.
struct Invocation: Equatable {
    var command: Command
    var file: String?
    var profiles: Set<String> = []
    var positionals: [String] = []
    var follow = false
    var tail: Int?
    var noCache = false
}

enum ParsedArguments: Equatable {
    /// Print this text on stdout and exit 0.
    case help(String)
    case run(Invocation)
    /// Print this text on stderr and exit 1.
    case failure(String)
}

/// Parses `container compose` argument vectors.
///
/// The grammar is global options → subcommand → the subcommand's own options and
/// operands, with `--` ending option parsing. Anything unrecognized, missing a
/// value, or unacceptable to the named subcommand is an error — nothing is
/// silently dropped.
enum CommandLineParser {

    static func parse(_ arguments: [String]) -> ParsedArguments {
        guard !arguments.isEmpty else { return .help(usage) }

        var file: String?
        var profiles: Set<String> = []
        var positionals: [String] = []
        var follow = false
        var tail: Int?
        var noCache = false
        var command: Command?
        var endOfOptions = false

        var index = 0
        /// Consumes and returns the argument after the current one.
        func nextValue() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            defer { index += 1 }
            let argument = arguments[index]

            if !endOfOptions {
                switch argument {
                case "--":
                    endOfOptions = true
                    continue
                case "-h", "--help":
                    return .help(command.map(help(for:)) ?? usage)
                case "-f", "--file":
                    guard let path = nextValue() else {
                        return .failure(missingValue(argument, "<file>", command))
                    }
                    file = path
                    continue
                case "--profile":
                    guard let name = nextValue() else {
                        return .failure(missingValue(argument, "<name>", command))
                    }
                    profiles.insert(name)
                    continue
                default:
                    break
                }

                if argument.hasPrefix("-") {
                    guard let command else {
                        return .failure("Unknown option '\(argument)'.\n\n\(usage)")
                    }
                    guard let option = CommandOption(rawValue: argument),
                        command.spec.options.contains(option)
                    else {
                        return .failure(unknownOption(argument, command))
                    }
                    switch option {
                    case .follow:
                        follow = true
                    case .noCache:
                        noCache = true
                    case .tail:
                        guard let raw = nextValue() else {
                            return .failure(missingValue(argument, "<n>", command))
                        }
                        guard let count = Int(raw), count >= 0 else {
                            return .failure(
                                "Invalid value for --tail: '\(raw)' (expected a non-negative integer).")
                        }
                        tail = count
                    }
                    continue
                }
            }

            // A bare word, or anything after `--`: the subcommand, then its operands.
            if command == nil {
                guard let parsed = Command(rawValue: argument) else {
                    return .failure("Unknown command '\(argument)'.\n\n\(usage)")
                }
                command = parsed
            } else {
                positionals.append(argument)
            }
        }

        guard let command else { return .failure(usage) }
        if let message = validate(positionals, for: command) { return .failure(message) }

        return .run(Invocation(
            command: command, file: file, profiles: profiles, positionals: positionals,
            follow: follow, tail: tail, noCache: noCache))
    }

    // MARK: - validation

    private static func validate(_ positionals: [String], for command: Command) -> String? {
        switch command.spec.positionals {
        case .none(let hint):
            guard !positionals.isEmpty else { return nil }
            return """
                `compose \(command.rawValue)` takes no arguments, but got: \(positionals.joined(separator: ", ")).
                \(hint)
                """
        case .atMostOne(let name):
            guard positionals.count > 1 else { return nil }
            return "`compose \(command.rawValue)` takes at most one \(name), but got: "
                + "\(positionals.joined(separator: ", "))."
        case .any:
            return nil
        }
    }

    private static func missingValue(_ option: String, _ placeholder: String, _ command: Command?) -> String {
        let scope = command.map { "compose \($0.rawValue)" } ?? "compose"
        return "Option '\(option)' needs a value: \(scope) \(option) \(placeholder)"
    }

    private static func unknownOption(_ option: String, _ command: Command) -> String {
        """
        Unknown option '\(option)' for `compose \(command.rawValue)`.

        \(help(for: command))
        """
    }

    // MARK: - help

    static var usage: String {
        """
        OVERVIEW: Define and run multi-container apps with Apple container.

        USAGE: container compose [-f <file>] [--profile <name>]... <command> [args]

        COMMANDS:
        \(table(Command.allCases.map { ($0.synopsis, $0.spec.summary) }))

        OPTIONS:
        \(table(globalOptionRows))

        Run 'container compose <command> --help' for a command's own options.
        """
    }

    static func help(for command: Command) -> String {
        let spec = command.spec
        return """
            OVERVIEW: \(spec.summary)

            USAGE: container compose [-f <file>] [--profile <name>]... \(command.synopsis)

            \(spec.discussion)

            OPTIONS:
            \(table(spec.options.map { ($0.usageLabel, $0.summary) } + globalOptionRows))
            """
    }

    private static let globalOptionRows: [(String, String)] = [
        ("-f, --file <file>", "Compose file (default: ./compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml)"),
        ("--profile <name>", "Activate a compose profile (repeatable)"),
        ("-h, --help", "Show this help"),
    ]

    /// Two-column layout with the descriptions aligned and wrapped under the column.
    private static func table(_ rows: [(String, String)]) -> String {
        let width = rows.map(\.0.count).max() ?? 0
        let indent = String(repeating: " ", count: width + 4)
        return rows.map { label, description in
            let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
            return "  \(padded)  " + wrap(description, width: 78 - width - 4, indent: indent)
        }.joined(separator: "\n")
    }

    private static func wrap(_ text: String, width: Int, indent: String) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " \(word)"
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n\(indent)")
    }
}
