import ComposeGraph
import ComposeModel
import ComposeTranslate
import ContainerEngine
import Foundation

/// `container compose …` — parses argv, loads the compose file, and drives the
/// orchestrator. Returns the process exit code instead of calling `exit`, so the
/// whole flow is testable; `Sources/compose` is a thin `@main` shim over this.
/// A value written by a task and read once it finishes.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?
    var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// Set from the signal handler, read after the task finishes.
private final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func raise() { lock.withLock { value = true } }
    var raised: Bool { lock.withLock { value } }
}

public enum ComposeCLI {

    public static func run(_ context: CLIContext) async -> Int32 {
        let invocation: Invocation
        switch CommandLineParser.parse(context.arguments) {
        case .help(let text):
            context.write(text + "\n")
            return 0
        case .failure(let message):
            return fail(message, context)
        case .run(let parsed):
            invocation = parsed
        }

        do {
            return try await execute(invocation, context)
        } catch let error as OrchestratorError {
            return fail(describe(error), context)
        } catch let error as EngineError {
            return fail(
                "container \(error.argv.joined(separator: " ")) failed (exit \(error.exitCode))\n\(error.stderr)",
                context)
        } catch {
            return fail("\(error)", context)
        }
    }

    private static func execute(_ invocation: Invocation, _ context: CLIContext) async throws -> Int32 {
        let orchestrator = ComposeOrchestrator(engine: context.makeEngine())
        let profiles = invocation.profiles
        // Every command reads the compose file: it names the project whose
        // containers the command acts on, `ps` and `down` included.
        let loaded = try loadProject(file: invocation.file, context: context)
        // What the file itself is wrong about matters to every command, not just the
        // ones that start containers. `config` prints its own aggregate below.
        if invocation.command != .config {
            printWarnings(loaded.warnings, context, verbose: invocation.verbose)
        }

        switch invocation.command {
        case .up where !invocation.detach:
            return try await foregroundUp(
                project: loaded.project, baseDirectory: loaded.baseDirectory, profiles: profiles,
                orchestrator: orchestrator, context: context, verbose: invocation.verbose)

        case .up:
            let included = ComposeGraph.includedServices(loaded.project, activeProfiles: profiles)
            printWarnings(
                preflight(
                    project: loaded.project, baseDirectory: loaded.baseDirectory,
                    services: included, context: context),
                context, verbose: invocation.verbose)
            let options = TranslateOptions(baseDirectory: loaded.baseDirectory)
            let result = try await orchestrator.up(
                project: loaded.project, activeProfiles: profiles, options: options)
            printWarnings(result.warnings, context, verbose: invocation.verbose)
            return report(result, context)

        case .down:
            let removed = try await orchestrator.down(project: loaded.project, activeProfiles: profiles)
            let name = ComposeNaming.projectName(loaded.project)
            context.write(removed.isEmpty
                ? "No containers to remove for \(name).\n"
                : "Removed \(removed.count) container(s) from \(name).\n")
            return 0

        case .build:
            for service in invocation.positionals where loaded.project.services[service] == nil {
                return fail("no such service: \(service)", context)
            }
            let built = try await orchestrator.build(
                project: loaded.project, services: invocation.positionals,
                noCache: invocation.noCache, baseDirectory: loaded.baseDirectory)
            if built.isEmpty {
                context.write(invocation.positionals.isEmpty
                    ? "No services with a build: section.\n"
                    : "No buildable services among: \(invocation.positionals.joined(separator: ", ")).\n")
            } else {
                context.write("Built \(built.count) image(s).\n")
            }
            return 0

        case .ps:
            let containers = try await orchestrator.containers(project: loaded.project)
            guard !containers.isEmpty else {
                context.write(
                    "No containers for \(ComposeNaming.projectName(loaded.project)). Start them with: container compose up\n")
                return 0
            }
            context.write(ContainerTable.render(containers) + "\n")
            return 0

        case .logs:
            let service = invocation.positionals.first
            if let service, loaded.project.services[service] == nil {
                return fail("no such service: \(service)", context)
            }
            guard !loaded.project.serviceNames.isEmpty else {
                return fail("no services defined in compose file", context)
            }
            // A named service passes straight through, so its output is untouched;
            // with none named, every service is multiplexed under its own prefix.
            if let service {
                return try await orchestrator.logs(
                    project: loaded.project, service: service,
                    follow: invocation.follow, tail: invocation.tail)
            }
            let project = loaded.project
            let printer = multiplexer(for: project, profiles: profiles, context: context)
            let following = invocation.follow
            let tail = invocation.tail
            let interrupted = await untilInterrupted {
                try? await orchestrator.follow(
                    project: project, activeProfiles: profiles, follow: following, tail: tail
                ) { service, line in
                    printer.line(service, line)
                }
            }
            restoreInterrupt()
            return interrupted ? 130 : 0

        case .stop:
            let stopped = try await orchestrator.stop(project: loaded.project, activeProfiles: profiles)
            context.write(count(stopped, "Stopped", "stop", loaded.project))
            return 0

        case .start:
            let started = try await orchestrator.start(project: loaded.project, activeProfiles: profiles)
            context.write(count(started, "Started", "start", loaded.project))
            return 0

        case .restart:
            let restarted = try await orchestrator.restart(
                project: loaded.project, activeProfiles: profiles)
            context.write(count(restarted, "Restarted", "restart", loaded.project))
            return 0

        case .pull:
            for service in invocation.positionals where loaded.project.services[service] == nil {
                return fail("no such service: \(service)", context)
            }
            let pulled = try await orchestrator.pull(
                project: loaded.project, services: invocation.positionals)
            context.write(pulled.isEmpty
                ? (invocation.positionals.isEmpty
                    ? "No services declare an image to pull.\n"
                    : "No image to pull among: \(invocation.positionals.joined(separator: ", ")).\n")
                : "Pulled \(pulled.count) image(s).\n")
            return 0

        case .exec:
            let service = invocation.positionals[0]
            guard loaded.project.services[service] != nil else {
                return fail("no such service: \(service)", context)
            }
            return try await orchestrator.exec(
                project: loaded.project, service: service,
                command: Array(invocation.positionals.dropFirst()), tty: context.isTTY)

        case .config:
            let document = try ComposeParser.interpolatedDocument(
                loaded.yaml,
                projectNameFallback: ComposeNaming.projectName(loaded.project),
                environment: loaded.environment)
            context.write(document)
            // `config` is where you go to find out why something was ignored, so it
            // gathers every diagnostic the pipeline can produce — parsing, preflight
            // and translation — at every severity, info included.
            let options = TranslateOptions(baseDirectory: loaded.baseDirectory)
            var diagnostics = loaded.warnings
            diagnostics += preflight(
                project: loaded.project, baseDirectory: loaded.baseDirectory,
                services: Set(loaded.project.serviceNames), context: context)
            diagnostics += loaded.project.serviceNames.flatMap {
                ComposeTranslate.runArgs(serviceName: $0, project: loaded.project, options: options)
                    .warnings
            }
            // A dependency `up` would refuse to resolve is exactly the kind of thing
            // `config` exists to surface.
            if case .failure(let error) = ComposeGraph.startupPlan(
                loaded.project, activeProfiles: profiles) {
                diagnostics.append(Warning(
                    kind: .unsupportedValue, key: "depends_on",
                    message: "dependency error: \(error)", severity: .blocking))
            }
            printWarnings(diagnostics.sortedForDisplay(), context, verbose: true)
            return diagnostics.contains { $0.severity == .blocking } ? 1 : 0
        }
    }

    /// "Stopped 3 container(s) in demo." / "No containers to stop in demo."
    private static func count(
        _ names: [String], _ past: String, _ verb: String, _ project: ComposeProject
    ) -> String {
        let name = ComposeNaming.projectName(project)
        guard !names.isEmpty else { return "No containers to \(verb) in \(name).\n" }
        return "\(past) \(names.count) container(s) in \(name).\n"
    }

    // MARK: - foreground up

    /// Docker's foreground behavior: start the stack, follow every service's log,
    /// and stop the containers — without removing them — when the logs end or the
    /// user interrupts.
    ///
    /// SIGINT is trapped across the whole span, start phase included. Trapping it
    /// only around the follow would leave a Ctrl-C during a slow pull or build
    /// killing the process outright, with whatever containers it had already created
    /// still running.
    private static func foregroundUp(
        project: ComposeProject, baseDirectory: String, profiles: Set<String>,
        orchestrator: ComposeOrchestrator, context: CLIContext, verbose: Bool
    ) async throws -> Int32 {
        let printer = multiplexer(for: project, profiles: profiles, context: context)
        let outcome = Box<Result<UpResult, Error>>()
        let startCode = Box<Int32>()

        let interrupted = await untilInterrupted {
            do {
                let result = try await orchestrator.up(
                    project: project, activeProfiles: profiles,
                    options: TranslateOptions(baseDirectory: baseDirectory))
                outcome.value = .success(result)
                // Reported here rather than after the follow, so the summary reaches
                // the terminal before the logs it summarizes.
                printWarnings(result.warnings, context, verbose: verbose)
                startCode.value = report(result, context)
                guard !result.running.isEmpty else { return }
                try await orchestrator.follow(
                    project: project, activeProfiles: profiles
                ) { service, line in
                    printer.line(service, line)
                }
            } catch {
                outcome.value = .failure(error)
            }
        }

        // Whatever the start produced is worth reporting before unwinding.
        var code: Int32 = 0
        var anythingToStop = true
        switch outcome.value {
        case .failure(let error):
            restoreInterrupt()
            throw error
        case .success(let result):
            code = startCode.value ?? 0
            anythingToStop = !result.running.isEmpty
        case .none:
            // Interrupted before `up` returned; containers may exist regardless.
            break
        }

        if anythingToStop {
            context.write("Stopping\u{2026}\n")
            _ = try await orchestrator.stop(project: project, activeProfiles: profiles)
        }
        restoreInterrupt()
        // 130 is the shell's convention for "terminated by SIGINT".
        return interrupted ? 130 : code
    }

    private static func multiplexer(
        for project: ComposeProject, profiles: Set<String>, context: CLIContext
    ) -> LogMultiplexer {
        let included = ComposeGraph.includedServices(project, activeProfiles: profiles)
        return LogMultiplexer(
            services: project.serviceNames.filter(included.contains),
            colour: context.isOutputTTY,
            write: context.write)
    }

    /// Runs `body` to completion, or cancels it on Ctrl-C. Returns whether it was
    /// interrupted.
    ///
    /// SIGINT's default disposition is disabled *before* the work starts, so no
    /// interrupt can kill the process between the two, and stays disabled on return —
    /// the caller usually has cleanup to do that a second Ctrl-C should not cut
    /// short. `restoreInterrupt()` puts it back.
    private static func untilInterrupted(_ body: @escaping @Sendable () async -> Void) async -> Bool {
        let flag = InterruptFlag()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let task = Task(operation: body)
        source.setEventHandler {
            flag.raise()
            task.cancel()
        }
        source.resume()
        await task.value
        source.cancel()
        return flag.raised
    }

    private static func restoreInterrupt() { signal(SIGINT, SIG_DFL) }

    // MARK: - helpers

    struct LoadedProject {
        let project: ComposeProject
        let warnings: [Warning]
        let baseDirectory: String
        /// The file as read, for `config` to re-render without resolving the path again.
        let yaml: String
        let environment: (String) -> String?
    }

    static func loadProject(file: String?, context: CLIContext) throws -> LoadedProject {
        let path = try resolveFile(file, context: context)
        let yaml = try context.readFile(path)
        // Absolute dir of the compose file; relative build/bind/env_file paths resolve
        // against this (Compose semantics), so `up` works regardless of the shell CWD.
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let dotEnv = try loadDotEnv(directory: directory.path, context: context)
        // The process environment wins over `.env`, as in Compose.
        let environment = { (name: String) in context.environment[name] ?? dotEnv[name] }
        let result = try ComposeParser.parse(
            yaml, projectNameFallback: directory.lastPathComponent, environment: environment)
        return LoadedProject(
            project: result.project, warnings: result.warnings, baseDirectory: directory.path,
            yaml: yaml, environment: environment)
    }

    /// The `.env` beside the compose file, if there is one. A file that exists but
    /// cannot be read is an error: silently interpolating without it would start the
    /// stack with the wrong values.
    private static func loadDotEnv(directory: String, context: CLIContext) throws -> [String: String] {
        let path = "\(directory)/.env"
        guard context.pathKind(path) == .file else { return [:] }
        do {
            return DotEnv.parse(try context.readFile(path))
        } catch {
            throw CLIError("cannot read \(path): \(error)")
        }
    }

    /// Preflight on bind mounts: a source that points at a file (Apple `container`
    /// bind-mounts directories only), and a target at a database data directory
    /// (the engine rejects the `chown` those images perform). Restricted to
    /// `services` — the profile-included set — so `up --profile …` stays quiet
    /// about services it will not start.
    private static func preflight(
        project: ComposeProject, baseDirectory: String, services: Set<String>, context: CLIContext
    ) -> [Warning] {
        ComposeTranslate.preflightWarnings(
            project: project,
            options: TranslateOptions(baseDirectory: baseDirectory),
            services: services,
            kind: context.pathKind
        )
    }

    static func resolveFile(_ file: String?, context: CLIContext) throws -> String {
        if let file {
            guard context.pathKind(file) != .missing else {
                throw CLIError("compose file not found: \(file)")
            }
            return file
        }
        let candidates = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
        for candidate in candidates {
            let path = "\(context.currentDirectory)/\(candidate)"
            if context.pathKind(path) != .missing { return path }
        }
        throw CLIError(
            "no compose file found in \(context.currentDirectory) (looked for \(candidates.joined(separator: ", ")))")
    }

    /// `.info` diagnostics are noise in a normal run and the reason for a surprise in
    /// a bad one, so they are hidden unless asked for — by `--verbose`, or by `config`,
    /// whose whole job is to explain what happened to the file.
    private static func printWarnings(
        _ warnings: [Warning], _ context: CLIContext, verbose: Bool = false
    ) {
        for warning in warnings where verbose || warning.severity != .info {
            let scope = warning.service.map { "[\($0)] " } ?? ""
            let label = warning.severity == .info ? "note" : "warning"
            context.writeError("\(label): \(scope)\(warning.message)\n")
        }
    }

    /// `up`'s closing line, and its exit code: a stack whose services all died is a
    /// failure, however cleanly each `container run` returned. Services that were
    /// meant to exit (one-shot jobs) count as started, not as casualties.
    private static func report(_ result: UpResult, _ context: CLIContext) -> Int32 {
        guard !result.stopped.isEmpty else {
            context.write("Started \(result.total) service(s).\n")
            return 0
        }
        let alive = result.running.count + result.completed.count
        context.write("Started \(alive)/\(result.total) service(s).\n")
        for service in result.stopped {
            context.write("'\(service)' is not running. Check its log: container compose logs \(service)\n")
        }
        return result.running.isEmpty ? 1 : 0
    }

    private static func describe(_ error: OrchestratorError) -> String {
        switch error {
        case .systemNotRunning:
            return "container system is not running. Start it with: container system start"
        case .graph(let graphError):
            return "dependency error: \(graphError)"
        case .blocking(let warnings):
            return "cannot start:\n" + warnings.map { "  - \($0.message)" }.joined(separator: "\n")
        case .conflict(let conflicts):
            let lines = conflicts.map { conflict -> String in
                let owner = conflict.owner.map { "project '\($0)'" } ?? "no compose project"
                return "  - '\(conflict.name)' (service '\(conflict.service)') belongs to \(owner)"
            }
            return """
                cannot start: these container names are taken by containers this project does not own:
                \(lines.joined(separator: "\n"))

                Starting would destroy them. Remove them yourself (container delete <name>), or give \
                the service a free name with container_name:.
                """
        }
    }

    private static func fail(_ message: String, _ context: CLIContext) -> Int32 {
        context.writeError(message + "\n")
        return 1
    }
}
