import ComposeModel
import Testing

@testable import ComposeTranslate

/// `ComposeNaming` is the one place that decides what a container is called. The
/// argv and the orchestrator's stop/remove/logs calls all read from it, so these
/// tests double as the guarantee that a stack cannot start under one name and be
/// looked up under another.
@Suite("Naming")
struct ComposeNamingTests {

    private func project(_ yaml: String) throws -> ComposeProject {
        try ComposeParser.parse(yaml, projectNameFallback: "fallback").project
    }

    private static let sample = """
        name: demo
        services:
          web:
            image: nginx
          db:
            image: mysql
            container_name: my-db
        """

    @Test("without a domain: container_name wins, else <project>-<service>")
    func plainNames() throws {
        let proj = try project(Self.sample)
        #expect(ComposeNaming.containerName(project: proj, service: "web", domain: nil) == "demo-web")
        #expect(ComposeNaming.containerName(project: proj, service: "db", domain: nil) == "my-db")
    }

    @Test("a project with no name: falls back to the directory-derived name")
    func fallbackProjectName() throws {
        let proj = try project("services:\n  web:\n    image: nginx")
        #expect(ComposeNaming.containerName(project: proj, service: "web", domain: nil) == "fallback-web")
    }

    @Test("with a domain the name is a FQDN whose label is the service name")
    func fqdnNames() throws {
        let proj = try project(Self.sample)
        #expect(ComposeNaming.containerName(project: proj, service: "web", domain: "test") == "web.test")
        #expect(ComposeNaming.containerName(project: proj, service: "db", domain: "test") == "my-db.test")
    }

    @Test("an empty domain is treated as no domain")
    func emptyDomain() throws {
        let proj = try project(Self.sample)
        #expect(ComposeNaming.containerName(project: proj, service: "web", domain: "") == "demo-web")
    }

    @Test("the run argv takes its --name from the same helper")
    func argvUsesHelper() throws {
        let proj = try project(Self.sample)
        for service in proj.serviceNames {
            let argv = ComposeTranslate.runArgs(serviceName: service, project: proj).argv
            let expected = ComposeNaming.containerName(project: proj, service: service, domain: nil)
            #expect(argv.firstIndex(of: "--name").map { argv[$0 + 1] } == expected)
        }
    }

    @Test("the image tag matches the tag the run argv uses for a build: service")
    func imageTagMatchesRunArgv() throws {
        let proj = try project("""
            name: demo
            services:
              app:
                build: ./app
            """)
        let argv = ComposeTranslate.runArgs(serviceName: "app", project: proj).argv
        let tag = ComposeNaming.imageTag(project: proj, service: "app")
        #expect(tag == "demo-app:compose")
        #expect(argv.last == tag)
        #expect(ComposeTranslate.buildArgs(serviceName: "app", project: proj)?.tag == tag)
    }
}
