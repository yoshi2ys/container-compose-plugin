import Testing

@testable import ComposeCLICore

/// Characterization tests: they pin the CLI's observable behavior (exit code,
/// stdout, stderr, engine calls) so later refactors of the parser and the
/// command layer are provably behavior-preserving.
@Suite("compose CLI")
struct ComposeCLITests {

    private static let stack = """
        name: demo
        services:
          web:
            image: nginx
          worker:
            image: alpine
            depends_on: [web]
        """

    private static let files = ["/work/compose.yaml": stack]

    // MARK: - help / unknown

    @Test("no arguments prints usage on stdout and exits 0")
    func noArguments() async {
        let run = await runCLI([])
        #expect(run.exitCode == 0)
        #expect(run.stdout.hasPrefix("OVERVIEW:"))
        #expect(run.stderr.isEmpty)
    }

    @Test("--help after a command prints that command's help and touches nothing")
    func helpFlag() async {
        let run = await runCLI(["up", "--help"])
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("USAGE: container compose [-f <file>] [--profile <name>]... up"))
        #expect(run.operations.isEmpty)
    }

    @Test("an extra positional is an error rather than a silent no-op")
    func extraPositional() async {
        let run = await runCLI(["up", "web"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("takes no arguments, but got: web"))
        #expect(run.operations.isEmpty)
    }

    @Test("unknown command fails with usage on stderr")
    func unknownCommand() async {
        let run = await runCLI(["frobnicate"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("Unknown command 'frobnicate'."))
        #expect(run.stdout.isEmpty)
    }

    @Test("only options and no command fails with usage")
    func noCommand() async {
        let run = await runCLI(["--profile", "dev"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("OVERVIEW:"))
    }

    // MARK: - compose file resolution

    @Test("-f pointing at a missing file reports it")
    func missingExplicitFile() async {
        let run = await runCLI(["-f", "/nope.yaml", "up"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("compose file not found: /nope.yaml"))
    }

    @Test("no compose file in the working directory reports the candidates")
    func noComposeFile() async {
        let run = await runCLI(["up"])
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("no compose file found in /work"))
        #expect(run.stderr.contains("docker-compose.yml"))
    }

    @Test("the default lookup order finds compose.yaml first")
    func defaultLookup() async {
        let run = await runCLI(
            ["up"],
            files: ["/work/compose.yaml": Self.stack, "/work/docker-compose.yml": "services: {}"])
        #expect(run.exitCode == 0)
        #expect(run.operations == ["rm:demo-web", "run:demo-web", "rm:demo-worker", "run:demo-worker"])
    }

    // MARK: - up

    @Test("up starts the stack and reports the count")
    func upStartsStack() async {
        let run = await runCLI(["up"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "Started 2 service(s).\n")
        #expect(run.operations == ["rm:demo-web", "run:demo-web", "rm:demo-worker", "run:demo-worker"])
    }

    @Test("up counts only profile-included services")
    func upWithProfile() async {
        let files = ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx
              debugger:
                image: busybox
                profiles: [dev]
            """]
        let run = await runCLI(["up"], files: files)
        #expect(run.stdout == "Started 1 service(s).\n")

        let withProfile = await runCLI(["--profile", "dev", "up"], files: files)
        #expect(withProfile.stdout == "Started 2 service(s).\n")
    }

    @Test("up reports a stopped container system without touching containers")
    func upSystemDown() async {
        let run = await runCLI(["up"], files: Self.files, engine: RecordingEngine(running: false))
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("container system is not running"))
        #expect(run.operations.isEmpty)
    }

    @Test("up refuses a service with neither image nor build")
    func upBlockingWarning() async {
        let run = await runCLI(["up"], files: ["/work/compose.yaml": """
            name: demo
            services:
              broken: {}
            """])
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("cannot start:"))
        #expect(run.stderr.contains("neither 'image' nor 'build'"))
    }

    @Test("up reports a dependency cycle")
    func upCycle() async {
        let run = await runCLI(["up"], files: ["/work/compose.yaml": """
            name: demo
            services:
              a:
                image: x
                depends_on: [b]
              b:
                image: x
                depends_on: [a]
            """])
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("dependency error:"))
    }

    // MARK: - warnings

    @Test("warning-level diagnostics go to stderr scoped by service; info stays hidden")
    func warningsOnStderr() async {
        let run = await runCLI(["up"], files: ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx
                restart: always
                mem_swappiness: 1
                ports: ["80:80"]
            """])
        #expect(run.exitCode == 0)
        #expect(run.stderr.contains("warning: [web] Key 'mem_swappiness' on service 'web' is not supported"))
        #expect(run.stderr.contains("warning: [web] Apple container has no restart policy"))
        // `.info`: privileged port and unknown top-level keys are suppressed today.
        #expect(!run.stderr.contains("privileged host port"))
    }

    @Test("a bind source that is a file is flagged before start")
    func bindFilePreflight() async {
        let run = await runCLI(
            ["up"],
            files: [
                "/work/compose.yaml": """
                    name: demo
                    services:
                      web:
                        image: nginx
                        volumes:
                          - ./nginx.conf:/etc/nginx/nginx.conf
                    """,
                "/work/nginx.conf": "server {}",
            ])
        #expect(run.exitCode == 0)
        #expect(run.stderr.contains("bind-mounts directories only"))
    }

    // MARK: - down / ps / logs / build

    @Test("down removes the stack in reverse order and names the project")
    func downRemoves() async {
        let run = await runCLI(["down"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "Removed demo.\n")
        #expect(run.operations == ["stop:demo-worker", "rm:demo-worker", "stop:demo-web", "rm:demo-web"])
    }

    @Test("ps forwards to `container list --all` and returns its exit code")
    func psForwards() async {
        let run = await runCLI(["ps"], files: Self.files, engine: RecordingEngine(forwardExit: 7))
        #expect(run.exitCode == 7)
        #expect(run.operations == ["forward:list --all"])
    }

    @Test("logs defaults to the first service and passes --follow/--tail through")
    func logsDefaults() async {
        let run = await runCLI(["logs", "--follow", "--tail", "5"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.operations == ["forward:logs -f -n 5 demo-web"])
    }

    @Test("logs for an unknown service fails")
    func logsUnknownService() async {
        let run = await runCLI(["logs", "nope"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("no such service: nope"))
    }

    @Test("build with no build: sections says so")
    func buildNothingToBuild() async {
        let run = await runCLI(["build"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "No services with a build: section.\n")
    }

    @Test("build passes --no-cache through and reports the count")
    func buildNoCache() async {
        let run = await runCLI(["build", "--no-cache"], files: ["/work/compose.yaml": """
            name: demo
            services:
              app:
                build: ./app
            """])
        #expect(run.exitCode == 0)
        #expect(run.stdout == "Built 1 image(s).\n")
        #expect(run.operations == ["build:demo-app:compose"])
    }

    @Test("build for an unknown service fails")
    func buildUnknownService() async {
        let run = await runCLI(["build", "nope"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("no such service: nope"))
    }
}
