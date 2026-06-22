import ComposeGraph
import ComposeModel
import ComposeTranslate
import ContainerEngine
import Foundation

/// `container compose …` — a CLI plugin that runs multi-container apps from a
/// compose file by driving the `container` CLI.
@main
struct ComposeCLI {
    static let usage = """
        OVERVIEW: Define and run multi-container apps with Apple container.

        USAGE: container compose [-f <file>] [--profile <name>]... <command> [args]

        COMMANDS:
          up                 Create and start the stack (dependency order)
          down               Stop and remove the stack (reverse order)
          build [service...] Build images for services with a build: section
                             (--no-cache to ignore the builder's layer cache)
          ps                 List the stack's containers
          logs [service]     Show logs (--follow, --tail <n>)

        OPTIONS:
          -f, --file <file>  Compose file (default: ./compose.yaml, compose.yml,
                             docker-compose.yaml, docker-compose.yml)
          --profile <name>   Activate a compose profile (repeatable)
          --no-cache         Build without the builder's layer cache (build only)
          -h, --help         Show this help
        """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args.contains("-h") || args.contains("--help") {
            print(usage)
            return
        }

        var file: String?
        var profiles: Set<String> = []
        var positional: [String] = []
        var follow = false
        var tail: Int?
        var noCache = false

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "-f", "--file": file = iterator.next()
            case "--profile": if let value = iterator.next() { profiles.insert(value) }
            case "--follow": follow = true
            case "--tail": tail = iterator.next().flatMap(Int.init)
            case "--no-cache": noCache = true
            default: positional.append(arg)
            }
        }

        guard let command = positional.first else {
            fail(usage)
        }
        let extras = Array(positional.dropFirst())

        do {
            let engine = CLIContainerEngine()
            let orchestrator = ComposeOrchestrator(engine: engine)

            switch command {
            case "up":
                let (project, warnings, baseDirectory) = try loadProject(file: file)
                printWarnings(warnings)
                let included = ComposeGraph.includedServices(project, activeProfiles: profiles)
                printWarnings(preflight(project: project, baseDirectory: baseDirectory, services: included))
                let options = TranslateOptions(baseDirectory: baseDirectory)
                let runWarnings = try await orchestrator.up(
                    project: project, activeProfiles: profiles, options: options)
                printWarnings(runWarnings)
                print("Started \(included.count) service(s).")
            case "down":
                let (project, _, _) = try loadProject(file: file)
                try await orchestrator.down(project: project, activeProfiles: profiles)
                print("Removed \(project.name ?? "compose").")
            case "build":
                let (project, warnings, baseDirectory) = try loadProject(file: file)
                printWarnings(warnings)
                for service in extras where project.services[service] == nil {
                    fail("no such service: \(service)")
                }
                let built = try await orchestrator.build(
                    project: project, services: extras, noCache: noCache, baseDirectory: baseDirectory)
                if built.isEmpty {
                    print(extras.isEmpty
                        ? "No services with a build: section."
                        : "No buildable services among: \(extras.joined(separator: ", ")).")
                } else {
                    print("Built \(built.count) image(s).")
                }
            case "ps":
                let code = try await orchestrator.ps()
                exit(code)
            case "logs":
                let (project, _, _) = try loadProject(file: file)
                if let service = extras.first, project.services[service] == nil {
                    fail("no such service: \(service)")
                }
                guard !project.serviceNames.isEmpty else { fail("no services defined in compose file") }
                let code = try await orchestrator.logs(
                    project: project, service: extras.first, follow: follow, tail: tail)
                exit(code)
            default:
                fail("Unknown command '\(command)'.\n\n\(usage)")
            }
        } catch let error as OrchestratorError {
            fail(describe(error))
        } catch let error as EngineError {
            fail("container \(error.argv.joined(separator: " ")) failed (exit \(error.exitCode))\n\(error.stderr)")
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - helpers

    private static func loadProject(
        file: String?
    ) throws -> (project: ComposeProject, warnings: [Warning], baseDirectory: String) {
        let path = try resolveFile(file)
        let yaml = try String(contentsOfFile: path, encoding: .utf8)
        // Absolute dir of the compose file; relative build/bind/env_file paths resolve
        // against this (Compose semantics), so `up` works regardless of the shell CWD.
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let result = try ComposeParser.parse(yaml, projectNameFallback: directory.lastPathComponent)
        return (result.project, result.warnings, directory.path)
    }

    /// Filesystem preflight: flag bind sources that point at a file (Apple `container`
    /// bind-mounts directories only). Restricted to `services` (the profile-included set).
    private static func preflight(
        project: ComposeProject, baseDirectory: String, services: Set<String>
    ) -> [Warning] {
        ComposeTranslate.preflightWarnings(
            project: project,
            options: TranslateOptions(baseDirectory: baseDirectory),
            services: services
        ) { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
            return isDirectory.boolValue ? .directory : .file
        }
    }

    private static func resolveFile(_ file: String?) throws -> String {
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw CLIError("compose file not found: \(file)")
            }
            return file
        }
        let candidates = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
        let cwd = FileManager.default.currentDirectoryPath
        for candidate in candidates {
            let path = "\(cwd)/\(candidate)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        throw CLIError("no compose file found in \(cwd) (looked for \(candidates.joined(separator: ", ")))")
    }

    private static func printWarnings(_ warnings: [Warning]) {
        for warning in warnings where warning.severity != .info {
            let scope = warning.service.map { "[\($0)] " } ?? ""
            FileHandle.standardError.write(Data("warning: \(scope)\(warning.message)\n".utf8))
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

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
