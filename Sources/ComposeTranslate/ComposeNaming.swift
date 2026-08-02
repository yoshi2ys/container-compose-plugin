import ComposeModel

/// The single authority on container names and image tags.
///
/// (Network and volume names are not derived — they are used as written in the
/// compose file; see `ComposeTranslate.prerequisites`.)
///
/// Container names are needed in three places (translation, startup, teardown);
/// when they disagree, a stack starts under one name and `down` looks for
/// another. Everything routes through here, and `domain` has no default, so the
/// DNS domain — the one piece of state that rewrites a name — cannot be supplied
/// in one place and forgotten in the others.
public enum ComposeNaming {

    /// The container name for a service.
    ///
    /// `container_name` always wins, verbatim: the compose file is naming the
    /// container exactly, and rewriting it would surprise anyone who wrote an FQDN
    /// there themselves.
    ///
    /// Otherwise: `<project>-<service>`, or `<service>.<domain>` when a DNS domain
    /// applies — Apple `container` registers a container in its resolver only when
    /// the name is fully qualified, and the label under the domain is the service
    /// name, so siblings reach it by the name the compose file uses.
    public static func containerName(
        project: ComposeProject, service: String, domain: String?
    ) -> String {
        if let explicit = project.services[service]?.containerName { return explicit }
        guard let domain, !domain.isEmpty else { return "\(projectName(project))-\(service)" }
        return "\(service).\(domain)"
    }

    /// The DNS domain a project's containers live under: `<project>.<registered>`.
    ///
    /// Two labels deep so two projects can each have a service called `web` without
    /// fighting over `web.test`. Measured on container 1.1.0: the engine's resolver
    /// answers for a two-label subdomain after a single
    /// `container system dns create <registered>` — no separate registration needed.
    public static func dnsDomain(project: ComposeProject, registered: String?) -> String? {
        guard let registered, !registered.isEmpty else { return nil }
        return "\(projectName(project)).\(registered)"
    }

    /// The tag given to an image built from a service's `build:` section.
    public static func imageTag(project: ComposeProject, service: String) -> String {
        "\(projectName(project))-\(service.lowercased()):compose"
    }

    /// The project's name. `ComposeParser` always fills one in, so the fallback is
    /// only for a `ComposeProject` built by hand.
    public static func projectName(_ project: ComposeProject) -> String {
        project.name ?? "compose"
    }
}
