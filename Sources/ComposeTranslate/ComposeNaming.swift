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
    /// Without a DNS domain: `container_name` if the service sets one, else
    /// `<project>-<service>`.
    ///
    /// With a domain, the name becomes a FQDN — Apple `container` registers a
    /// container in its internal resolver only when the name is fully qualified.
    /// The label under the domain is the **service name** (or `container_name`),
    /// so siblings reach it by the name the compose file uses.
    public static func containerName(
        project: ComposeProject, service: String, domain: String?
    ) -> String {
        let explicit = project.services[service]?.containerName
        guard let domain, !domain.isEmpty else {
            return explicit ?? "\(projectName(project))-\(service)"
        }
        return "\(explicit ?? service).\(domain)"
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
