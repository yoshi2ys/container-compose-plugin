import ComposeModel

/// Labels stamped on every container so we can reconstruct project/service
/// ownership from `container list --format json`.
public enum ComposeLabels {
    public static let project = "com.composeforcontainer.project"
    public static let service = "com.composeforcontainer.service"
}

public struct TranslateOptions: Sendable {
    public var detach: Bool
    /// R3: compose semantics keep stopped containers until `down`, so default off.
    public var removeOnExit: Bool
    /// When set, `--cidfile <path>` is added so the engine can capture the real ID.
    public var cidfilePath: String?

    public init(detach: Bool = true, removeOnExit: Bool = false, cidfilePath: String? = nil) {
        self.detach = detach
        self.removeOnExit = removeOnExit
        self.cidfilePath = cidfilePath
    }
}

public struct TranslationResult: Sendable, Equatable {
    public var argv: [String]
    public var warnings: [Warning]
    public init(argv: [String], warnings: [Warning]) {
        self.argv = argv
        self.warnings = warnings
    }
}

/// A network or volume that must exist before `up` (created idempotently).
public enum Prerequisite: Sendable, Equatable {
    case network(name: String, argv: [String])
    case volume(name: String, argv: [String])
}

/// Pure translation of compose definitions into `container` CLI argument vectors.
public enum ComposeTranslate {

    // MARK: run / create

    public static func runArgs(
        serviceName: String,
        project: ComposeProject,
        options: TranslateOptions = TranslateOptions()
    ) -> TranslationResult {
        guard let svc = project.services[serviceName] else {
            return TranslationResult(argv: [], warnings: [Warning(
                kind: .unsupportedValue, service: serviceName,
                message: "Service '\(serviceName)' not found.", severity: .blocking)])
        }
        let projectName = project.name ?? "compose"
        var argv: [String] = ["run"]
        var warnings: [Warning] = []

        if options.detach { argv += ["-d"] }
        if options.removeOnExit { argv += ["--rm"] }

        argv += ["--name", svc.containerName ?? "\(projectName)-\(serviceName)"]
        if let cid = options.cidfilePath { argv += ["--cidfile", cid] }

        argv += ["--label", "\(ComposeLabels.project)=\(projectName)"]
        argv += ["--label", "\(ComposeLabels.service)=\(serviceName)"]
        for label in svc.labels { argv += ["--label", "\(label.key)=\(label.value)"] }

        for e in svc.environment.entries {
            argv += ["-e", e.value.map { "\(e.key)=\($0)" } ?? e.key]
        }
        for file in svc.envFile { argv += ["--env-file", file] }

        if let wd = svc.workingDir { argv += ["-w", wd] }
        if let user = svc.user { argv += ["-u", user] }
        if let cpus = svc.deploy?.cpus { argv += ["-c", cpus] }
        if let memory = svc.deploy?.memory { argv += ["-m", normalizeMemory(memory)] }

        for cap in svc.capAdd { argv += ["--cap-add", cap] }
        for cap in svc.capDrop { argv += ["--cap-drop", cap] }
        for server in svc.dns { argv += ["--dns", server] }
        for domain in svc.dnsSearch { argv += ["--dns-search", domain] }

        if svc.readOnly == true { argv += ["--read-only"] }
        if svc.initProcess == true { argv += ["--init"] }
        if let platform = svc.platform { argv += ["--platform", platform] }
        for entry in svc.tmpfs {
            let path = entry.split(separator: ":", maxSplits: 1).first.map(String.init) ?? entry
            argv += ["--tmpfs", path]
            if entry.contains(":") {
                warnings.append(Warning(
                    kind: .engineGap(.tmpfsSize), service: serviceName, key: "tmpfs",
                    message: "tmpfs size/mode options are not supported inline; mounted '\(path)' without them.",
                    severity: .warning))
            }
        }

        appendPorts(svc, serviceName: serviceName, into: &argv, warnings: &warnings)
        appendVolumes(svc, into: &argv, warnings: &warnings, serviceName: serviceName)
        appendNetworks(svc, serviceName: serviceName, into: &argv, warnings: &warnings)
        appendGaps(svc, serviceName: serviceName, warnings: &warnings)

        let entrypointExtras = appendEntrypoint(svc, serviceName: serviceName, into: &argv, warnings: &warnings)

        // image (positional) then command (positional).
        if let image = svc.image {
            argv += [image]
        } else if svc.build != nil {
            argv += [derivedTag(projectName: projectName, serviceName: serviceName)]
        } else {
            warnings.append(Warning(
                kind: .unsupportedValue, service: serviceName,
                message: "Service '\(serviceName)' has neither 'image' nor 'build'; cannot start.",
                severity: .blocking))
        }

        argv += entrypointExtras + commandArguments(svc.command)
        return TranslationResult(argv: argv, warnings: warnings)
    }

    // MARK: build

    /// `nil` when the service has no `build:` section.
    public static func buildArgs(
        serviceName: String,
        project: ComposeProject
    ) -> (argv: [String], tag: String)? {
        guard let svc = project.services[serviceName], let build = svc.build else { return nil }
        let tag = derivedTag(projectName: project.name ?? "compose", serviceName: serviceName)
        var argv = ["build", "-t", tag]
        if let dockerfile = build.dockerfile { argv += ["-f", dockerfile] }
        for arg in build.args.entries {
            argv += ["--build-arg", arg.value.map { "\(arg.key)=\($0)" } ?? arg.key]
        }
        if let target = build.target { argv += ["--target", target] }
        if let platform = svc.platform { argv += ["--platform", platform] }
        argv += [build.context]
        return (argv, tag)
    }

    // MARK: prerequisites

    /// Networks and volumes to create before `up`, deduplicated across the project
    /// (top-level definitions plus any referenced by services), excluding `external`.
    public static func prerequisites(_ project: ComposeProject) -> [Prerequisite] {
        let externalNetworks = Set(project.networks.filter { $0.value.external }.keys)
        let externalVolumes = Set(project.volumes.filter { $0.value.external }.keys)

        var networks = Set(project.networks.filter { !$0.value.external }.keys)
        var volumes = Set(project.volumes.filter { !$0.value.external }.keys)

        for svc in project.services.values {
            for attach in svc.networks where !externalNetworks.contains(attach.name) {
                networks.insert(attach.name)
            }
            for volume in svc.volumes {
                if case .named(let name, _, _) = volume, !externalVolumes.contains(name) {
                    volumes.insert(name)
                }
            }
        }

        var result: [Prerequisite] = []
        for name in networks.sorted() {
            var argv = ["network", "create", name]
            if let def = project.networks[name] {
                if def.internalOnly { argv += ["--internal"] }
                if let subnet = def.subnet { argv += ["--subnet", subnet] }
            }
            result.append(.network(name: name, argv: argv))
        }
        for name in volumes.sorted() {
            result.append(.volume(name: name, argv: ["volume", "create", name]))
        }
        return result
    }

    // MARK: helpers

    static func derivedTag(projectName: String, serviceName: String) -> String {
        "\(projectName)-\(serviceName.lowercased()):compose"
    }
}
