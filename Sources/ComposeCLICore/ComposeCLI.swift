import ComposeGraph
import ComposeModel
import ComposeTranslate
import ContainerEngine
import Foundation

/// `container compose …` — parses argv, loads the compose file, and drives the
/// orchestrator. Returns the process exit code instead of calling `exit`, so the
/// whole flow is testable; `Sources/compose` is a thin `@main` shim over this.
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

        switch invocation.command {
        case .up:
            printWarnings(loaded.warnings, context)
            let included = ComposeGraph.includedServices(loaded.project, activeProfiles: profiles)
            printWarnings(
                preflight(
                    project: loaded.project, baseDirectory: loaded.baseDirectory,
                    services: included, context: context),
                context)
            let options = TranslateOptions(baseDirectory: loaded.baseDirectory)
            let result = try await orchestrator.up(
                project: loaded.project, activeProfiles: profiles, options: options)
            printWarnings(result.warnings, context)
            return report(result, context)

        case .down:
            let removed = try await orchestrator.down(project: loaded.project, activeProfiles: profiles)
            let name = ComposeNaming.projectName(loaded.project)
            context.write(removed.isEmpty
                ? "No containers to remove for \(name).\n"
                : "Removed \(removed.count) container(s) from \(name).\n")
            return 0

        case .build:
            printWarnings(loaded.warnings, context)
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
            return try await orchestrator.logs(
                project: loaded.project, service: service,
                follow: invocation.follow, tail: invocation.tail)
        }
    }

    // MARK: - helpers

    static func loadProject(
        file: String?, context: CLIContext
    ) throws -> (project: ComposeProject, warnings: [Warning], baseDirectory: String) {
        let path = try resolveFile(file, context: context)
        let yaml = try context.readFile(path)
        // Absolute dir of the compose file; relative build/bind/env_file paths resolve
        // against this (Compose semantics), so `up` works regardless of the shell CWD.
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let dotEnv = try loadDotEnv(directory: directory.path, context: context)
        let result = try ComposeParser.parse(
            yaml, projectNameFallback: directory.lastPathComponent
        ) { name in
            // The process environment wins over `.env`, as in Compose.
            context.environment[name] ?? dotEnv[name]
        }
        return (result.project, result.warnings, directory.path)
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

    private static func printWarnings(_ warnings: [Warning], _ context: CLIContext) {
        for warning in warnings where warning.severity != .info {
            let scope = warning.service.map { "[\($0)] " } ?? ""
            context.writeError("warning: \(scope)\(warning.message)\n")
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
