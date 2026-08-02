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

        switch invocation.command {
        case .up:
            let loaded = try loadProject(file: invocation.file, context: context)
            printWarnings(loaded.warnings, context)
            let included = ComposeGraph.includedServices(loaded.project, activeProfiles: profiles)
            printWarnings(
                preflight(
                    project: loaded.project, baseDirectory: loaded.baseDirectory,
                    services: included, context: context),
                context)
            let options = TranslateOptions(baseDirectory: loaded.baseDirectory)
            let runWarnings = try await orchestrator.up(
                project: loaded.project, activeProfiles: profiles, options: options)
            printWarnings(runWarnings, context)
            context.write("Started \(included.count) service(s).\n")
            return 0

        case .down:
            let loaded = try loadProject(file: invocation.file, context: context)
            try await orchestrator.down(project: loaded.project, activeProfiles: profiles)
            context.write("Removed \(ComposeNaming.projectName(loaded.project)).\n")
            return 0

        case .build:
            let loaded = try loadProject(file: invocation.file, context: context)
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
            return try await orchestrator.ps()

        case .logs:
            let loaded = try loadProject(file: invocation.file, context: context)
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
        let result = try ComposeParser.parse(yaml, projectNameFallback: directory.lastPathComponent)
        return (result.project, result.warnings, directory.path)
    }

    /// Filesystem preflight: flag bind sources that point at a file (Apple `container`
    /// bind-mounts directories only). Restricted to `services` (the profile-included set).
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

    private static func describe(_ error: OrchestratorError) -> String {
        switch error {
        case .systemNotRunning:
            return "container system is not running. Start it with: container system start"
        case .graph(let graphError):
            return "dependency error: \(graphError)"
        case .blocking(let warnings):
            return "cannot start:\n" + warnings.map { "  - \($0.message)" }.joined(separator: "\n")
        }
    }

    private static func fail(_ message: String, _ context: CLIContext) -> Int32 {
        context.writeError(message + "\n")
        return 1
    }
}
