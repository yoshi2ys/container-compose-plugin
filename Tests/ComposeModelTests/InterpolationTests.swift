import Testing

@testable import ComposeModel

@Suite("Interpolation")
struct InterpolationTests {

    private static let env = ["SET": "value", "EMPTY": "", "PORT": "8080"]

    private func expand(_ template: String) -> Result<Interpolation, InterpolationError> {
        Interpolator.expand(template) { Self.env[$0] }
    }

    private func value(_ template: String) -> String? {
        try? expand(template).get().value
    }

    private func failure(_ template: String) -> InterpolationError? {
        guard case .failure(let error) = expand(template) else { return nil }
        return error
    }

    /// The whole supported grammar, in one table. `EMPTY` is set but empty, which is
    /// what separates the `:` forms from their bare counterparts.
    @Test(
        "the supported forms substitute as the Compose spec says",
        arguments: [
            ("$SET", "value"),
            ("${SET}", "value"),
            ("prefix-$SET-suffix", "prefix-value-suffix"),
            ("${SET}${SET}", "valuevalue"),
            ("$MISSING", ""),
            ("${MISSING}", ""),
            ("${SET:-fallback}", "value"),
            ("${EMPTY:-fallback}", "fallback"),
            ("${MISSING:-fallback}", "fallback"),
            ("${SET-fallback}", "value"),
            ("${EMPTY-fallback}", ""),
            ("${MISSING-fallback}", "fallback"),
            ("${SET:?boom}", "value"),
            ("${SET?boom}", "value"),
            ("${EMPTY?boom}", ""),
            ("${MISSING:-}", ""),
            ("$$SET", "$SET"),
            ("$$", "$"),
            ("a$$b", "a$b"),
            ("100%", "100%"),
            ("no variables here", "no variables here"),
            ("$", "$"),
            ("$ SET", "$ SET"),
            ("$1", "$1"),
            ("http://localhost:${PORT}/", "http://localhost:8080/"),
        ])
    func supportedForms(template: String, expected: String) {
        #expect(value(template) == expected)
    }

    @Test("a variable with no value is reported so the caller can warn")
    func unsetIsReported() throws {
        let result = try expand("$MISSING-${ALSO_MISSING}").get()
        #expect(result.value == "-")
        #expect(result.unset == ["MISSING", "ALSO_MISSING"])
    }

    @Test("a default silences the unset report — the author supplied the value")
    func defaultSilencesUnsetReport() throws {
        #expect(try expand("${MISSING:-x}").get().unset.isEmpty)
    }

    @Test("${VAR:?} rejects unset and empty; ${VAR?} rejects only unset")
    func requiredForms() {
        #expect(failure("${MISSING:?set it in .env}")
            == .required(variable: "MISSING", message: "set it in .env"))
        #expect(failure("${EMPTY:?needed}") == .required(variable: "EMPTY", message: "needed"))
        #expect(failure("${MISSING?}") == .required(variable: "MISSING", message: nil))
        #expect(failure("${EMPTY?boom}") == nil)  // set, though empty
    }

    @Test(
        "malformed or unsupported references are errors, never a silent guess",
        arguments: [
            "${SET",
            "${}",
            "${1BAD}",
            "${SET:+other}",
            "${SET/a/b}",
            "${A:-${SET}}",
            "${A:-$SET}",
            "${A:-x$$y}",
        ])
    func malformedReferences(template: String) {
        #expect(failure(template) != nil, "expected '\(template)' to fail")
    }

    @Test("each failure explains itself")
    func errorMessages() {
        #expect(failure("${SET")?.description.contains("closing brace") == true)
        #expect(failure("${A:-${SET}}")?.description.contains("inside a default") == true)
        #expect(failure("${SET:+x}")?.description.contains("does not support") == true)
        #expect(failure("${MISSING:?set it}")?.description == "required variable 'MISSING' is missing: set it")
    }
}

@Suite(".env")
struct DotEnvTests {

    @Test("assignments, comments, blank lines and export")
    func basics() {
        let parsed = DotEnv.parse("""
            # a comment
            TAG=1.2.3

            export DB_USER=app
              SPACED  =  padded
            NOT AN ASSIGNMENT
            EMPTY=
            """)
        #expect(parsed == [
            "TAG": "1.2.3", "DB_USER": "app", "SPACED": "padded", "EMPTY": "",
        ])
    }

    @Test("quoting: single quotes are literal, double quotes take escapes")
    func quoting() {
        let parsed = DotEnv.parse("""
            SINGLE='a #b $c'
            DOUBLE="line\\nbreak"
            ESCAPED="say \\"hi\\""
            BACKSLASH="a\\\\b"
            UNKNOWN_ESCAPE="a\\qb"
            """)
        #expect(parsed["SINGLE"] == "a #b $c")
        #expect(parsed["DOUBLE"] == "line\nbreak")
        #expect(parsed["ESCAPED"] == #"say "hi""#)
        #expect(parsed["BACKSLASH"] == #"a\b"#)
        #expect(parsed["UNKNOWN_ESCAPE"] == #"a\qb"#)
    }

    @Test("an unquoted value ends at a trailing comment, but keeps a bare #")
    func trailingComment() {
        let parsed = DotEnv.parse("""
            A=value # a note
            B=value#nospace
            """)
        #expect(parsed["A"] == "value")
        #expect(parsed["B"] == "value#nospace")
    }

    @Test("CRLF line endings are handled")
    func crlf() {
        #expect(DotEnv.parse("A=1\r\nB=2\r\n") == ["A": "1", "B": "2"])
    }

    @Test("a quoted value ends at its closing quote, comment and all")
    func quotedValueWithTrailingComment() {
        #expect(DotEnv.parse(#"A="a" # note"#)["A"] == "a")
        #expect(DotEnv.parse("A='a' # note")["A"] == "a")
        #expect(DotEnv.parse(#"A="a # inside""#)["A"] == "a # inside")
        #expect(DotEnv.parse(#"A="say \"hi\"" # note"#)["A"] == #"say "hi""#)
    }

    @Test("a value containing = keeps everything after the first one")
    func equalsInValue() {
        #expect(DotEnv.parse("URL=postgres://u:p@h/db?a=b")["URL"] == "postgres://u:p@h/db?a=b")
    }
}

@Suite("Interpolation in a compose file")
struct ComposeInterpolationTests {

    private func parse(_ yaml: String, _ env: [String: String] = [:]) throws -> ParseResult {
        try ComposeParser.parse(yaml, projectNameFallback: "p") { env[$0] }
    }

    /// Interpolation walks the YAML nodes, not the decoded model, so it reaches keys
    /// the model gained after it was written. This covers one value of each shape.
    @Test("every scalar in the document is interpolated, whatever key it sits under")
    func interpolatesEverywhere() throws {
        let result = try parse("""
            name: ${PROJECT}
            services:
              ${SERVICE}:
                image: nginx:${TAG:-latest}
                ports:
                  - "${PORT}:80"
                environment:
                  URL: "http://${HOST}/"
                volumes:
                  - "${DIR}/src:/var/www"
                command: ["sh", "-c", "echo ${GREETING}"]
            """, [
                "PROJECT": "shop", "SERVICE": "web", "PORT": "8080",
                "HOST": "example.test", "DIR": "./app", "GREETING": "hi",
            ])
        let project = result.project
        #expect(project.name == "shop")
        let web = try #require(project.services["web"])
        #expect(web.image == "nginx:latest")
        #expect(web.ports.first?.published == "8080")
        #expect(web.environment.entries.first?.value == "http://example.test/")
        #expect(web.volumes.first == .bind(source: "./app/src", target: "/var/www", readOnly: false))
        #expect(web.command == .exec(["sh", "-c", "echo hi"]))
    }

    @Test("an unset variable becomes an empty string and a warning")
    func unsetVariableWarns() throws {
        let result = try parse("""
            services:
              web:
                image: nginx:${TAG}
            """)
        #expect(result.project.services["web"]?.image == "nginx:")
        let warning = try #require(result.warnings.first { $0.kind == .unsetVariable })
        #expect(warning.key == "TAG")
        #expect(warning.severity == .warning)
    }

    @Test("a required variable stops the parse and names the key it came from")
    func requiredVariableIsBlocking() {
        #expect(throws: InterpolationFailure(
            path: "services.db.environment.MYSQL_ROOT_PASSWORD",
            reason: .required(variable: "ROOT_PASSWORD", message: "set it in .env"))
        ) {
            try parse("""
                services:
                  db:
                    image: mysql
                    environment:
                      MYSQL_ROOT_PASSWORD: ${ROOT_PASSWORD:?set it in .env}
                """)
        }
    }

    @Test("a failure inside a list reports the index")
    func failurePathInsideSequence() throws {
        let error = #expect(throws: InterpolationFailure.self) {
            try parse("""
                services:
                  web:
                    image: nginx
                    ports:
                      - "80:80"
                      - "${WEB_PORT:?required}:443"
                """)
        }
        #expect(error?.path == "services.web.ports[1]")
    }

    /// The one-pass rewrite has to keep the unsupported-key diff seeing exactly what
    /// the decoder sees. This is the regression guard for that.
    @Test("unsupported-key warnings survive the interpolating parse unchanged")
    func keyDiffStillWorks() throws {
        let result = try parse("""
            x-anchors: ignored
            services:
              web:
                image: nginx
                mem_swappiness: 1
                cgroup_parent: /x
            """)
        #expect(result.warnings.contains {
            $0.kind == .unsupportedKey && $0.key == "x-anchors" && $0.severity == .info
        })
        let serviceKeys = result.warnings.filter { $0.service == "web" }.compactMap(\.key)
        #expect(serviceKeys == ["cgroup_parent", "mem_swappiness"])
        #expect(result.project.services["web"]?.unknownKeys == ["cgroup_parent", "mem_swappiness"])
    }

    @Test("a key that interpolates into an unsupported name is diffed after substitution")
    func keyDiffSeesInterpolatedKeys() throws {
        let result = try parse("""
            services:
              web:
                image: nginx
                ${KEY}: 1
            """, ["KEY": "mem_swappiness"])
        #expect(result.warnings.contains { $0.key == "mem_swappiness" })
    }

    @Test("YAML anchors still expand, and their scalars are interpolated")
    func anchorsStillWork() throws {
        let result = try parse("""
            services:
              a: &base
                image: nginx:${TAG}
              b:
                <<: *base
            """, ["TAG": "1.25"])
        #expect(result.project.services["a"]?.image == "nginx:1.25")
        #expect(result.project.services["b"]?.image == "nginx:1.25")
    }

    @Test("YAML merge keys stay flattened: the key diff sees the merged-in keys")
    func mergeKeysAreFlattenedForTheKeyDiff() throws {
        let result = try parse("""
            x-base: &base
              image: nginx
              bogus_key: 1
            services:
              web:
                <<: *base
                ports: ["80:80"]
            """)
        // `<<` is YAML syntax, not a compose key — reporting it would be a false
        // positive, and it would hide the key that really is unsupported.
        #expect(result.warnings.allSatisfy { $0.key != "<<" })
        #expect(result.warnings.contains { $0.service == "web" && $0.key == "bogus_key" })
        #expect(result.project.services["web"]?.unknownKeys == ["bogus_key"])
        #expect(result.project.services["web"]?.image == "nginx")
    }

    @Test("an empty compose file is rejected, not read as an empty project")
    func emptyDocumentIsAnError() {
        #expect(throws: ComposeParseError.emptyDocument) { try parse("") }
        #expect(throws: ComposeParseError.emptyDocument) { try parse("# only a comment\n") }
    }

    @Test("`$$` reaches the container as a single dollar")
    func escapedDollar() throws {
        let result = try parse("""
            services:
              web:
                image: nginx
                environment:
                  COST: "$$5"
            """)
        #expect(result.project.services["web"]?.environment.entries.first?.value == "$5")
    }
}
