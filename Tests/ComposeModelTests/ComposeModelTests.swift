import Testing
@testable import ComposeModel

@Suite("Compose parsing")
struct ComposeModelTests {

    @Test("A typical two-service stack parses with normalized shapes")
    func parsesTwoServiceStack() throws {
        let yaml = """
        name: shop
        services:
          web:
            image: nginx:latest
            container_name: shop-web
            ports:
              - "8080:80"
              - "127.0.0.1:8443:443/tcp"
            environment:
              - DEBUG=true
              - INHERIT_ME
            volumes:
              - ./site:/usr/share/nginx/html:ro
            depends_on:
              - api
          api:
            image: my/api:1.2
            environment:
              LOG_LEVEL: info
              PORT: 3000
        """
        let result = try ComposeParser.parse(yaml, projectNameFallback: "fallback")
        #expect(result.project.name == "shop")
        #expect(result.project.serviceNames == ["api", "web"])

        let web = try #require(result.project.services["web"])
        #expect(web.image == "nginx:latest")
        #expect(web.containerName == "shop-web")

        #expect(web.ports.count == 2)
        #expect(web.ports[0] == PortMapping(published: "8080", target: "80"))
        #expect(web.ports[1] == PortMapping(hostIP: "127.0.0.1", published: "8443", target: "443", proto: "tcp"))

        // environment list: KEY=VAL and bare KEY (inherit)
        #expect(web.environment.entries.contains(EnvMap.Entry(key: "DEBUG", value: "true")))
        #expect(web.environment.entries.contains(EnvMap.Entry(key: "INHERIT_ME", value: nil)))

        #expect(web.volumes == [.bind(source: "./site", target: "/usr/share/nginx/html", readOnly: true)])
        #expect(web.dependsOn == [Dependency(service: "api", condition: .started)])

        // environment map form, with an unquoted int coerced to a string
        let api = try #require(result.project.services["api"])
        #expect(api.environment.entries == [
            EnvMap.Entry(key: "LOG_LEVEL", value: "info"),
            EnvMap.Entry(key: "PORT", value: "3000"),
        ])
    }

    @Test("Long-form ports decode")
    func longFormPorts() throws {
        let yaml = """
        services:
          a:
            image: x
            ports:
              - target: 80
                published: 8080
                protocol: tcp
        """
        let svc = try #require(try ComposeParser.parse(yaml, projectNameFallback: "p").project.services["a"])
        #expect(svc.ports == [PortMapping(published: "8080", target: "80", proto: "tcp")])
    }

    @Test("IPv6 host ports degrade instead of failing the parse")
    func ipv6Ports() throws {
        let yaml = """
        services:
          a:
            image: x
            ports:
              - "[::1]:8080:80"
              - "::1:9090:90"
        """
        let svc = try #require(try ComposeParser.parse(yaml, projectNameFallback: "p").project.services["a"])
        #expect(svc.ports[0] == PortMapping(hostIP: "::1", published: "8080", target: "80"))
        #expect(svc.ports[1] == PortMapping(hostIP: "::1", published: "9090", target: "90"))
    }

    @Test("depends_on map with conditions")
    func dependsOnConditions() throws {
        let yaml = """
        services:
          web:
            image: x
            depends_on:
              db:
                condition: service_healthy
              cache:
                condition: service_started
        """
        let web = try #require(try ComposeParser.parse(yaml, projectNameFallback: "p").project.services["web"])
        #expect(web.dependsOn == [
            Dependency(service: "cache", condition: .started),
            Dependency(service: "db", condition: .healthy),
        ])
    }

    @Test("command string vs array, named vs bind volumes")
    func commandAndVolumeForms() throws {
        let yaml = """
        services:
          shell:
            image: x
            command: "npm start"
            volumes:
              - dbdata:/var/lib/data
              - /etc/host.conf:/etc/host.conf
        """
        let svc = try #require(try ComposeParser.parse(yaml, projectNameFallback: "p").project.services["shell"])
        #expect(svc.command == .shell("npm start"))
        #expect(svc.volumes == [
            .named(volume: "dbdata", target: "/var/lib/data", readOnly: false),
            .bind(source: "/etc/host.conf", target: "/etc/host.conf", readOnly: false),
        ])
    }

    @Test("exec-form command array")
    func execCommand() throws {
        let yaml = """
        services:
          a:
            image: x
            command: ["sh", "-c", "echo hi"]
        """
        let svc = try #require(try ComposeParser.parse(yaml, projectNameFallback: "p").project.services["a"])
        #expect(svc.command == .exec(["sh", "-c", "echo hi"]))
    }

    @Test("restart policies parse")
    func restartPolicies() throws {
        func restart(_ value: String) throws -> RestartPolicy? {
            let yaml = "services:\n  a:\n    image: x\n    restart: \(value)\n"
            return try ComposeParser.parse(yaml, projectNameFallback: "p").project.services["a"]?.restart
        }
        #expect(try restart("always") == .always)
        #expect(try restart("unless-stopped") == .unlessStopped)
        #expect(try restart("\"no\"") == RestartPolicy.no)
        #expect(try restart("on-failure:5") == .onFailure(maxRetries: 5))
    }

    @Test("labels list and map forms")
    func labelForms() throws {
        let listYAML = """
        services:
          a:
            image: x
            labels:
              - "com.example.tier=frontend"
        """
        let mapYAML = """
        services:
          a:
            image: x
            labels:
              com.example.tier: frontend
        """
        let fromList = try #require(try ComposeParser.parse(listYAML, projectNameFallback: "p").project.services["a"])
        let fromMap = try #require(try ComposeParser.parse(mapYAML, projectNameFallback: "p").project.services["a"])
        let expected = [LabelPair(key: "com.example.tier", value: "frontend")]
        #expect(fromList.labels == expected)
        #expect(fromMap.labels == expected)
    }

    @Test("unsupported keys surface as warnings, not silent drops")
    func unsupportedKeyWarnings() throws {
        let yaml = """
        services:
          a:
            image: x
            shm_size: 64m
            cgroup_parent: /custom
        """
        let result = try ComposeParser.parse(yaml, projectNameFallback: "p")
        let svc = try #require(result.project.services["a"])
        #expect(svc.unknownKeys == ["cgroup_parent", "shm_size"])
        let keys = Set(result.warnings.filter { $0.kind == .unsupportedKey }.compactMap(\.key))
        #expect(keys.isSuperset(of: ["shm_size", "cgroup_parent"]))
        #expect(result.warnings.allSatisfy { $0.service == "a" || $0.service == nil })
    }

    @Test("project name falls back and is sanitized")
    func projectNameFallback() throws {
        let yaml = "services:\n  a:\n    image: x\n"
        let result = try ComposeParser.parse(yaml, projectNameFallback: "My Project!")
        #expect(result.project.name == "my-project")
    }

    @Test("top-level networks and volumes, including null values")
    func topLevelNetworksAndVolumes() throws {
        let yaml = """
        services:
          a:
            image: x
        networks:
          default:
          backend:
            internal: true
        volumes:
          dbdata:
          cache:
            external: true
        """
        let result = try ComposeParser.parse(yaml, projectNameFallback: "p")
        #expect(Set(result.project.networks.keys) == ["default", "backend"])
        #expect(result.project.networks["backend"]?.internalOnly == true)
        #expect(Set(result.project.volumes.keys) == ["dbdata", "cache"])
        #expect(result.project.volumes["cache"]?.external == true)
        #expect(result.project.volumes["dbdata"]?.external == false)
    }
}
