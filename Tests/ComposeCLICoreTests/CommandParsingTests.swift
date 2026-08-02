import Testing

@testable import ComposeCLICore

@Suite("Command line")
struct CommandParsingTests {

    private func failure(_ arguments: [String]) -> String? {
        guard case .failure(let message) = CommandLineParser.parse(arguments) else { return nil }
        return message
    }

    private func invocation(_ arguments: [String]) -> Invocation? {
        guard case .run(let invocation) = CommandLineParser.parse(arguments) else { return nil }
        return invocation
    }

    private func help(_ arguments: [String]) -> String? {
        guard case .help(let text) = CommandLineParser.parse(arguments) else { return nil }
        return text
    }

    // MARK: - each command's spec drives parsing

    /// Each command accepts the options its spec declares…
    @Test("declared options are accepted", arguments: Command.allCases)
    func declaredOptionsAccepted(command: Command) {
        for option in command.spec.options {
            let arguments = [command.rawValue, option.rawValue] + (option == .tail ? ["3"] : [])
            #expect(invocation(arguments)?.command == command, "\(command) should accept \(option.rawValue)")
        }
    }

    /// …and rejects the ones it does not, instead of ignoring them. This pairing is
    /// the point of the spec table: a flag is legal for exactly the commands that list it.
    @Test("undeclared options are rejected", arguments: Command.allCases)
    func undeclaredOptionsRejected(command: Command) {
        let declared = Set(command.spec.options)
        for option in CommandOption.allCases where !declared.contains(option) {
            let message = failure([command.rawValue, option.rawValue])
            #expect(
                message?.contains("Unknown option '\(option.rawValue)'") == true,
                "\(command) should reject \(option.rawValue), got: \(message ?? "no failure")")
        }
    }

    // MARK: - missing values

    @Test(
        "an option at the end of argv reports its missing value",
        arguments: [
            (["-f"], "-f"),
            (["--file"], "--file"),
            (["up", "--profile"], "--profile"),
            (["logs", "--tail"], "--tail"),
        ])
    func missingValue(arguments: [String], option: String) {
        let message = failure(arguments)
        #expect(message?.contains("Option '\(option)' needs a value") == true)
    }

    @Test("--tail rejects a non-integer")
    func tailNotAnInteger() {
        #expect(failure(["logs", "--tail", "soon"])?.contains("expected a non-negative integer") == true)
        // A negative count is consumed as the option's value, not read as a flag.
        #expect(failure(["logs", "--tail", "-3"])?.contains("Invalid value for --tail: '-3'") == true)
    }

    // MARK: - positionals

    @Test(
        "commands that take no operands reject them",
        arguments: [["up", "web"], ["down", "web"], ["ps", "web"]])
    func extraPositionalRejected(arguments: [String]) {
        let message = failure(arguments)
        #expect(message?.contains("takes no arguments, but got: web") == true)
    }

    @Test("`up web` explains that starting a subset is unsupported")
    func upSubsetHint() {
        #expect(failure(["up", "web"])?.contains("starting a subset is not supported yet") == true)
    }

    @Test("logs takes at most one service")
    func logsOneService() {
        #expect(invocation(["logs", "web"])?.positionals == ["web"])
        #expect(failure(["logs", "web", "db"])?.contains("at most one service") == true)
    }

    @Test("build takes any number of services")
    func buildServices() {
        #expect(invocation(["build"])?.positionals == [])
        #expect(invocation(["build", "web", "db"])?.positionals == ["web", "db"])
    }

    // MARK: - unknown input

    @Test("an unknown command is reported with the usage")
    func unknownCommand() {
        let message = failure(["frobnicate"])
        #expect(message?.hasPrefix("Unknown command 'frobnicate'.") == true)
        #expect(message?.contains("COMMANDS:") == true)
    }

    @Test("an unknown option before any command is reported with the usage")
    func unknownGlobalOption() {
        let message = failure(["--verbose", "up"])
        #expect(message?.hasPrefix("Unknown option '--verbose'.") == true)
    }

    @Test("options with no command at all fall back to the usage")
    func optionsWithoutCommand() {
        #expect(failure(["--profile", "dev"])?.contains("OVERVIEW:") == true)
    }

    // MARK: - globals, `--`, help

    @Test("global options are accepted before and after the command")
    func globalsEitherSide() {
        let before = invocation(["-f", "a.yaml", "--profile", "dev", "up"])
        let after = invocation(["up", "-f", "a.yaml", "--profile", "dev"])
        #expect(before == after)
        #expect(before?.file == "a.yaml")
        #expect(before?.profiles == ["dev"])
    }

    @Test("--profile is repeatable")
    func repeatableProfile() {
        #expect(invocation(["--profile", "dev", "--profile", "debug", "up"])?.profiles == ["dev", "debug"])
    }

    @Test("`--` ends option parsing; the rest is verbatim")
    func doubleDashPassthrough() {
        #expect(invocation(["build", "--", "--no-cache"])?.positionals == ["--no-cache"])
        #expect(invocation(["build", "--", "--no-cache"])?.noCache == false)
        #expect(invocation(["logs", "--", "-h"])?.positionals == ["-h"])
    }

    @Test("`--` before the subcommand still leaves the subcommand recognizable")
    func doubleDashBeforeCommand() {
        // Scripts prepend `--` defensively before forwarding "$@"; `--` ends option
        // parsing, it does not consume the operand that names the command.
        #expect(invocation(["--", "up"])?.command == .up)
        #expect(invocation(["--profile", "dev", "--", "logs", "web"])?.positionals == ["web"])
        #expect(failure(["--", "--tail"])?.hasPrefix("Unknown command '--tail'.") == true)
    }

    @Test("`--help` after a command shows that command's help", arguments: Command.allCases)
    func perCommandHelp(command: Command) {
        let text = help([command.rawValue, "--help"])
        #expect(text?.contains("USAGE: container compose") == true)
        #expect(text?.contains(command.synopsis) == true)
        for option in command.spec.options {
            #expect(text?.contains(option.rawValue) == true)
        }
    }

    @Test("no arguments shows the overall usage listing every command")
    func globalHelp() {
        let text = help([])
        for command in Command.allCases {
            #expect(text?.contains(command.synopsis) == true)
        }
    }

    @Test("--tail parses a count")
    func tailParsed() {
        #expect(invocation(["logs", "--tail", "20"])?.tail == 20)
        #expect(invocation(["logs", "--follow"])?.follow == true)
    }
}
