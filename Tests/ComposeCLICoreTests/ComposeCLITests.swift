import ContainerEngine
import EngineTestSupport
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
        let run = await runCLI(["up", "-d"])
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("no compose file found in /work"))
        #expect(run.stderr.contains("docker-compose.yml"))
    }

    @Test("the default lookup order finds compose.yaml first")
    func defaultLookup() async {
        let run = await runCLI(
            ["up", "-d"],
            files: ["/work/compose.yaml": Self.stack, "/work/docker-compose.yml": "services: {}"])
        #expect(run.exitCode == 0)
        #expect(run.operations == ["run:demo-web", "run:demo-worker"])
    }

    // MARK: - variables

    @Test("a .env beside the compose file supplies variables")
    func dotEnvIsRead() async {
        let run = await runCLI(["up", "-d"], files: [
            "/work/compose.yaml": """
                name: demo
                services:
                  web:
                    image: nginx:${TAG}
                """,
            "/work/.env": "TAG=1.25\n",
        ])
        #expect(run.exitCode == 0)
        #expect(run.runInvocations.first?.contains("nginx:1.25") == true)
        #expect(!run.stderr.contains("not set"))
    }

    @Test("the process environment wins over .env")
    func processEnvironmentWins() async {
        let files = [
            "/work/compose.yaml": """
                name: demo
                services:
                  web:
                    image: nginx
                    environment:
                      TAG: ${TAG}
                """,
            "/work/.env": "TAG=from-dotenv\n",
        ]
        let fromDotEnv = await runCLI(["up", "-d"], files: files)
        #expect(fromDotEnv.runInvocations.first?.contains("TAG=from-dotenv") == true)

        let overridden = await runCLI(["up", "-d"], files: files, environment: ["TAG": "from-process"])
        #expect(overridden.runInvocations.first?.contains("TAG=from-process") == true)
    }

    @Test("a variable with no value anywhere is a warning, not a failure")
    func unsetVariableWarnsButStarts() async {
        let run = await runCLI(["up", "-d"], files: ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx:${TAG}
            """])
        #expect(run.exitCode == 0)
        #expect(run.stderr.contains("The 'TAG' variable is not set"))
    }

    @Test("a required variable stops the command and names the key")
    func requiredVariableFails() async {
        let run = await runCLI(["up", "-d"], files: ["/work/compose.yaml": """
            name: demo
            services:
              db:
                image: mysql
                environment:
                  MYSQL_ROOT_PASSWORD: ${ROOT_PASSWORD:?put it in .env}
            """])
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("services.db.environment.MYSQL_ROOT_PASSWORD"))
        #expect(run.stderr.contains("required variable 'ROOT_PASSWORD' is missing: put it in .env"))
        #expect(run.operations.isEmpty)
    }

    @Test("no .env is not an error")
    func withoutDotEnv() async {
        let run = await runCLI(["up", "-d"], files: Self.files)
        #expect(run.exitCode == 0)
    }

    // MARK: - up

    @Test("up starts the stack and reports the count")
    func upStartsStack() async {
        let run = await runCLI(["up", "-d"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "Started 2 service(s).\n")
        #expect(run.operations == ["run:demo-web", "run:demo-worker"])
    }

    @Test("up follows the logs by default, then stops the stack when they end")
    func upFollowsInForeground() async {
        let engine = FakeEngine(logLines: ["demo-web": ["ready"], "demo-worker": ["tick"]])
        let run = await runCLI(["up"], files: Self.files, engine: engine)
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("web    | ready\n"))
        #expect(run.stdout.contains("worker | tick\n"))
        #expect(run.stdout.contains("Stopping"))
        // started, then stopped in reverse dependency order — not removed
        #expect(run.operations == [
            "run:demo-web", "run:demo-worker", "stop:demo-worker", "stop:demo-web",
        ])
    }

    @Test("a service's lines come out in order, and none is dropped")
    func multiplexerKeepsOrderAndLosesNothing() async {
        // The multiplexer is fed from a reader thread per service with no yielding,
        // which is where a per-line task would reorder and the process exit would
        // truncate.
        let lines = (0..<400).map { "web-\($0)" }
        let other = (0..<400).map { "worker-\($0)" }
        let engine = FakeEngine(
            containers: [
                composeContainer(project: "demo", service: "web"),
                composeContainer(project: "demo", service: "worker"),
            ],
            logLines: ["demo-web": lines, "demo-worker": other])
        let run = await runCLI(["logs"], files: Self.files, engine: engine)

        let webLines = run.stdout.split(separator: "\n")
            .filter { $0.hasPrefix("web ") }
            .compactMap { line -> String? in
                line.range(of: "| ").map { String(line[$0.upperBound...]) }
            }
        #expect(webLines.count == 400)
        #expect(webLines == lines)
        #expect(run.stdout.split(separator: "\n").filter { $0.hasPrefix("worker") }.count == 400)
    }

    @Test("-d starts the stack and returns without following anything")
    func upDetachDoesNotFollow() async {
        let engine = FakeEngine(logLines: ["demo-web": ["ready"]])
        let run = await runCLI(["up", "-d"], files: Self.files, engine: engine)
        #expect(run.stdout == "Started 2 service(s).\n")
        #expect(run.operations == ["run:demo-web", "run:demo-worker"])
    }

    @Test("up does not attach when nothing is left running")
    func upDoesNotAttachToADeadStack() async {
        let run = await runCLI(
            ["up"], files: Self.files, engine: FakeEngine(exiting: ["web", "worker"]))
        #expect(run.exitCode == 1)
        #expect(!run.stdout.contains("Stopping"))
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
        let run = await runCLI(["up", "-d"], files: files)
        #expect(run.stdout == "Started 1 service(s).\n")

        let withProfile = await runCLI(["--profile", "dev", "up", "-d"], files: files)
        #expect(withProfile.stdout == "Started 2 service(s).\n")
    }

    @Test("up refuses to destroy a container owned by another project")
    func upForeignContainerConflict() async {
        let engine = FakeEngine(containers: [
            composeContainer(project: "other", service: "www", name: "demo-web")
        ])
        let run = await runCLI(["up", "-d"], files: Self.files, engine: engine)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("'demo-web' (service 'web') belongs to project 'other'"))
        #expect(run.operations.isEmpty)
    }

    @Test("up refuses to destroy a container that carries no compose labels")
    func upUnlabelledContainerConflict() async {
        let engine = FakeEngine(containers: [
            ContainerSummary(id: "demo-web", image: "nginx", state: "running")
        ])
        let run = await runCLI(["up", "-d"], files: Self.files, engine: engine)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("belongs to no compose project"))
        #expect(run.operations.isEmpty)
    }

    @Test("up recreates the project's own containers without complaint")
    func upRecreatesOwnContainers() async {
        let engine = FakeEngine(containers: [
            composeContainer(project: "demo", service: "web")
        ])
        let run = await runCLI(["up", "-d"], files: Self.files, engine: engine)
        #expect(run.exitCode == 0)
        #expect(run.operations.contains("rm:demo-web"))
    }

    @Test("up reports a service that started and died, and where to look")
    func upReportsExitedService() async {
        let run = await runCLI(["up", "-d"], files: Self.files, engine: FakeEngine(exiting: ["worker"]))
        #expect(run.exitCode == 0)  // one service is still up
        #expect(run.stdout.contains("Started 1/2 service(s)."))
        #expect(run.stdout.contains("'worker' is not running. Check its log: container compose logs worker"))
    }

    @Test("up fails when every service died")
    func upAllServicesDied() async {
        let run = await runCLI(
            ["up", "-d"], files: Self.files, engine: FakeEngine(exiting: ["web", "worker"]))
        #expect(run.exitCode == 1)
        #expect(run.stdout.contains("Started 0/2 service(s)."))
    }

    @Test("up reports a stopped container system without touching containers")
    func upSystemDown() async {
        let run = await runCLI(["up", "-d"], files: Self.files, engine: FakeEngine(running: false))
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("container system is not running"))
        #expect(run.operations.isEmpty)
    }

    @Test("up refuses a service with neither image nor build")
    func upBlockingWarning() async {
        let run = await runCLI(["up", "-d"], files: ["/work/compose.yaml": """
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
        let run = await runCLI(["up", "-d"], files: ["/work/compose.yaml": """
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
        let run = await runCLI(["up", "-d"], files: ["/work/compose.yaml": """
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
            ["up", "-d"],
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

    @Test("down removes the project's containers in reverse order and counts them")
    func downRemoves() async {
        let engine = FakeEngine(containers: [
            composeContainer(project: "demo", service: "web"),
            composeContainer(project: "demo", service: "worker"),
            composeContainer(project: "other", service: "web", name: "other-web"),
        ])
        let run = await runCLI(["down"], files: Self.files, engine: engine)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "Removed 2 container(s) from demo.\n")
        #expect(run.operations == ["stop:demo-worker", "rm:demo-worker", "stop:demo-web", "rm:demo-web"])
    }

    @Test("down says so when the project has nothing running")
    func downNothing() async {
        let run = await runCLI(["down"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "No containers to remove for demo.\n")
        #expect(run.operations.isEmpty)
    }

    @Test("ps prints only the project's containers, as a table")
    func psTable() async {
        let engine = FakeEngine(containers: [
            composeContainer(
                project: "demo", service: "web", image: "nginx",
                ports: [PublishedPort(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")]),
            composeContainer(project: "other", service: "web", name: "other-web"),
            ContainerSummary(id: "buildkit", image: "builder", state: "running"),
        ])
        let run = await runCLI(["ps"], files: Self.files, engine: engine)
        #expect(run.exitCode == 0)
        #expect(run.stdout == """
            SERVICE  NAME      IMAGE  STATE    PORTS
            web      demo-web  nginx  running  0.0.0.0:8080->80/tcp

            """)
        #expect(!run.stdout.contains("buildkit"))
        #expect(!run.stdout.contains("other-web"))
    }

    @Test("ps on a stack that was never started points at up")
    func psEmpty() async {
        let run = await runCLI(["ps"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("No containers for demo."))
    }

    @Test("logs for a named service passes --follow/--tail straight through")
    func logsNamedService() async {
        let run = await runCLI(["logs", "--follow", "--tail", "5", "web"], files: Self.files)
        #expect(run.exitCode == 0)
        #expect(run.operations == ["forward:logs -f -n 5 demo-web"])
    }

    @Test("logs with no service multiplexes every service under its own prefix")
    func logsMultiplexesAllServices() async {
        let engine = FakeEngine(
            containers: [
                composeContainer(project: "demo", service: "web"),
                composeContainer(project: "demo", service: "worker"),
            ],
            logLines: ["demo-web": ["listening"], "demo-worker": ["polling"]])
        let run = await runCLI(["logs"], files: Self.files, engine: engine)
        #expect(run.exitCode == 0)
        // padded to the widest service name, and never a torn line
        #expect(run.stdout.contains("web    | listening\n"))
        #expect(run.stdout.contains("worker | polling\n"))
    }

    @Test("multiplexed logs are colourless when stdout is not a terminal")
    func logsNoColourWhenRedirected() async {
        let engine = FakeEngine(
            containers: [composeContainer(project: "demo", service: "web")],
            logLines: ["demo-web": ["plain"]])
        let redirected = await runCLI(["logs"], files: Self.files, engine: engine)
        #expect(!redirected.stdout.contains("\u{1B}["))
    }

    @Test("logs for an unknown service fails")
    func logsUnknownService() async {
        let run = await runCLI(["logs", "nope"], files: Self.files)
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("no such service: nope"))
    }

    // MARK: - stop / start / restart / pull / exec / config

    private static var runningStack: FakeEngine {
        FakeEngine(containers: [
            composeContainer(project: "demo", service: "web"),
            composeContainer(project: "demo", service: "worker"),
        ])
    }

    @Test("stop works in reverse dependency order and leaves the containers in place")
    func stopOrder() async {
        let run = await runCLI(["stop"], files: Self.files, engine: Self.runningStack)
        #expect(run.exitCode == 0)
        #expect(run.stdout == "Stopped 2 container(s) in demo.\n")
        #expect(run.operations == ["stop:demo-worker", "stop:demo-web"])
    }

    @Test("start works in dependency order and skips containers already running")
    func startOrder() async {
        let engine = FakeEngine(containers: [
            composeContainer(project: "demo", service: "web", state: "stopped"),
            composeContainer(project: "demo", service: "worker", state: "stopped"),
        ])
        let run = await runCLI(["start"], files: Self.files, engine: engine)
        #expect(run.operations == ["start:demo-web", "start:demo-worker"])

        let alreadyUp = await runCLI(["start"], files: Self.files, engine: Self.runningStack)
        #expect(alreadyUp.operations.isEmpty)
        #expect(alreadyUp.stdout == "No containers to start in demo.\n")
    }

    @Test("restart stops in reverse order, then starts in dependency order")
    func restartOrder() async {
        let run = await runCLI(["restart"], files: Self.files, engine: Self.runningStack)
        #expect(run.exitCode == 0)
        #expect(run.operations == [
            "stop:demo-worker", "stop:demo-web", "start:demo-web", "start:demo-worker",
        ])
    }

    @Test("stop/start touch nothing when the project has no containers")
    func lifecycleWithoutContainers() async {
        #expect(await runCLI(["stop"], files: Self.files).stdout == "No containers to stop in demo.\n")
    }

    @Test("pull fetches the image of every service that names one")
    func pullImages() async {
        let run = await runCLI(["pull"], files: ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx
              app:
                build: ./app
            """])
        #expect(run.exitCode == 0)
        #expect(run.operations == ["forward:image pull nginx"])
        #expect(run.stdout == "Pulled 1 image(s).\n")
    }

    @Test("pull says so when nothing has an image")
    func pullNothing() async {
        let run = await runCLI(["pull"], files: ["/work/compose.yaml": """
            name: demo
            services:
              app:
                build: ./app
            """])
        #expect(run.stdout == "No services declare an image to pull.\n")
    }

    @Test("exec attaches to the resolved container and passes the command through")
    func execRunsCommand() async {
        let engine = FakeEngine(containers: [
            composeContainer(project: "demo", service: "web", name: "renamed")
        ])
        let run = await runCLI(["exec", "web", "ls", "-la", "/srv"], files: Self.files, engine: engine)
        #expect(run.exitCode == 0)
        #expect(run.operations == ["forward:exec -i renamed ls -la /srv"])
    }

    @Test("exec does not eat the inner command's own options")
    func execPassesOptionsThrough() async {
        let run = await runCLI(
            ["exec", "web", "ls", "--tail", "--profile"], files: Self.files, engine: Self.runningStack)
        #expect(run.operations == ["forward:exec -i demo-web ls --tail --profile"])
    }

    @Test("exec asks for a TTY only when stdin is one")
    func execTTYOnlyWhenInteractive() async {
        // `container exec -t` fails with "Operation not supported by device" when
        // stdin is a pipe, which would break every scripted exec.
        let interactive = await runCLI(
            ["exec", "web", "sh"], files: Self.files, engine: Self.runningStack, isTTY: true)
        #expect(interactive.operations == ["forward:exec -i -t demo-web sh"])
    }

    @Test("exec needs a service and a command")
    func execRequiresArguments() async {
        #expect(await runCLI(["exec"], files: Self.files).stderr.contains("needs a service"))
        #expect(await runCLI(["exec", "web"], files: Self.files).stderr.contains("needs a command to run"))
        #expect(await runCLI(["exec", "nope", "ls"], files: Self.files).stderr.contains("no such service: nope"))
    }

    @Test("config prints the interpolated file and every diagnostic, info included")
    func configPrintsEverything() async {
        let run = await runCLI(["config"], files: [
            "/work/compose.yaml": """
                name: demo
                x-extra: ignored
                services:
                  web:
                    image: nginx:${TAG}
                    ports: ["80:80"]
                """,
            "/work/.env": "TAG=1.25\n",
        ])
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("nginx:1.25"))  // substituted, not "${TAG}"
        // info-level diagnostics that `up` keeps quiet about
        #expect(run.stderr.contains("note: Top-level key 'x-extra' is not supported"))
        #expect(run.stderr.contains("note: [web] Publishing privileged host port 80"))
    }

    @Test("config reports a dependency the graph cannot resolve, and fails")
    func configReportsGraphErrors() async {
        let run = await runCLI(["config"], files: ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx
                depends_on: [ghost]
            """])
        #expect(run.exitCode == 1)
        #expect(run.stderr.contains("dependency error"))
    }

    @Test("config shows the project name the other commands use, even when the file omits it")
    func configShowsResolvedProjectName() async {
        let run = await runCLI(["config"], files: ["/work/compose.yaml": "services:\n  web:\n    image: nginx\n"])
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("name: work"))
    }

    @Test("parse warnings reach every command, not just the ones that start containers")
    func warningsOnEveryCommand() async {
        let files = ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx:${TAG}
            """]
        for command in ["pull", "stop", "start", "restart", "ps", "down"] {
            let run = await runCLI([command], files: files)
            #expect(
                run.stderr.contains("The 'TAG' variable is not set"),
                "\(command) should report the unset variable")
        }
    }

    @Test("--verbose surfaces info diagnostics on other commands too")
    func verboseShowsInfo() async {
        let files = ["/work/compose.yaml": """
            name: demo
            services:
              web:
                image: nginx
                ports: ["80:80"]
            """]
        let quiet = await runCLI(["up", "-d"], files: files)
        #expect(!quiet.stderr.contains("privileged host port"))

        let loud = await runCLI(["--verbose", "up", "-d"], files: files)
        #expect(loud.stderr.contains("note: [web] Publishing privileged host port 80"))
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
