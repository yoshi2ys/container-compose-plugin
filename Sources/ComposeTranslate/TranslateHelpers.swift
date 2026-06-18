import ComposeModel

extension ComposeTranslate {

    static func appendPorts(
        _ svc: Service, serviceName: String,
        into argv: inout [String], warnings: inout [Warning]
    ) {
        for port in svc.ports {
            if port.isRange {
                let range = port.published.map { "\($0):\(port.target)" } ?? port.target
                warnings.append(Warning(
                    kind: .unsupportedValue, service: serviceName, key: "ports",
                    message: "Port range '\(range)' is not supported; use single ports.",
                    severity: .warning))
                continue
            }
            var spec = ""
            if let ip = port.hostIP { spec += "\(ip):" }
            if let published = port.published { spec += "\(published):" }
            spec += port.target
            if let proto = port.proto { spec += "/\(proto)" }
            argv += ["-p", spec]

            if let published = port.published, let number = Int(published), number < 1024 {
                warnings.append(Warning(
                    kind: .engineGap(.privilegedPort), service: serviceName, key: "ports",
                    message: "Publishing privileged host port \(number) may require elevated permissions on macOS.",
                    severity: .info))
            }
        }
    }

    static func appendVolumes(
        _ svc: Service,
        into argv: inout [String], warnings: inout [Warning], serviceName: String,
        baseDirectory: String? = nil
    ) {
        for volume in svc.volumes {
            switch volume {
            case .bind(let source, let target, let readOnly):
                let resolvedSource = resolvePath(source, relativeTo: baseDirectory)
                var mount = "type=bind,source=\(resolvedSource),target=\(target)"
                if readOnly { mount += ",readonly" }
                argv += ["--mount", mount]
                if !readOnly {
                    warnings.append(Warning(
                        kind: .engineGap(.readOnlyBindNonRoot), service: serviceName, key: "volumes",
                        message: "Bind mount '\(source)': for non-root container users, writes may be blocked (known runtime limitation).",
                        severity: .info))
                }
            case .named(let name, let target, let readOnly):
                var mount = "type=volume,source=\(name),target=\(target)"
                if readOnly { mount += ",readonly" }
                argv += ["--mount", mount]
            case .anonymous(let target):
                argv += ["--mount", "type=volume,target=\(target)"]
            }
        }
    }

    static func appendNetworks(
        _ svc: Service, serviceName: String,
        into argv: inout [String], warnings: inout [Warning]
    ) {
        guard let first = svc.networks.first else { return }
        argv += ["--network", first.name]
        if svc.networks.count > 1 {
            let ignored = svc.networks.dropFirst().map(\.name).joined(separator: ", ")
            warnings.append(Warning(
                kind: .engineGap(.multiNetwork), service: serviceName, key: "networks",
                message: "Only one network per container is supported; attached '\(first.name)', ignored: \(ignored).",
                severity: .warning))
        }
    }

    /// Warnings for features Apple `container` cannot honor (restart, healthcheck, DNS).
    static func appendGaps(_ svc: Service, serviceName: String, warnings: inout [Warning]) {
        if let restart = svc.restart, restart != .no {
            warnings.append(Warning(
                kind: .engineGap(.restart), service: serviceName, key: "restart",
                message: "Apple container has no restart policy; enable app-managed restart to emulate '\(restartDescription(restart))'.",
                severity: .warning))
        }
        if let healthcheck = svc.healthcheck, healthcheck.disable != true, !healthcheck.test.isEmpty {
            warnings.append(Warning(
                kind: .engineGap(.healthcheck), service: serviceName, key: "healthcheck",
                message: "Apple container does not run healthchecks continuously; this plugin runs the check only at `up`, to gate a dependent's `depends_on: service_healthy` (it is not re-run after start).",
                severity: .warning))
        }
    }

    /// Adds `--entrypoint` and returns extra entrypoint args to fold into the command (R5).
    static func appendEntrypoint(
        _ svc: Service, serviceName: String,
        into argv: inout [String], warnings: inout [Warning]
    ) -> [String] {
        guard let entrypoint = svc.entrypoint else { return [] }
        switch entrypoint {
        case .shell(let value):
            argv += ["--entrypoint", value]
            return []
        case .exec(let parts):
            guard let first = parts.first else { return [] }
            argv += ["--entrypoint", first]
            let extras = Array(parts.dropFirst())
            if !extras.isEmpty {
                warnings.append(Warning(
                    kind: .emulated("entrypoint args folded into command"), service: serviceName, key: "entrypoint",
                    message: "Multi-element entrypoint: used '\(first)' as entrypoint; remaining args prepended to the command.",
                    severity: .info))
            }
            return extras
        }
    }

    static func commandArguments(_ command: CommandSpec?) -> [String] {
        switch command {
        case .none: return []
        case .shell(let value): return tokenize(value)
        case .exec(let parts): return parts
        }
    }

    /// Compose memory ("512m", "1gb", "1G") → container's K/M/G/T/P form.
    static func normalizeMemory(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let last = value.last, last == "b" || last == "B" { value = String(value.dropLast()) }
        if let last = value.last, last.isLetter { value = value.dropLast() + last.uppercased() }
        return value
    }

    static func restartDescription(_ policy: RestartPolicy) -> String {
        switch policy {
        case .no: return "no"
        case .always: return "always"
        case .unlessStopped: return "unless-stopped"
        case .onFailure(let max): return max.map { "on-failure:\($0)" } ?? "on-failure"
        }
    }

    /// Minimal quote-aware splitter for shell-form `command:` strings.
    static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in string {
            if let active = quote {
                if ch == active { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
