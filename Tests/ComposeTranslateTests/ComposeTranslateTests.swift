import Testing
import ComposeModel
@testable import ComposeTranslate

@Suite("Translation to container argv")
struct ComposeTranslateTests {

    private func project(_ yaml: String) throws -> ComposeProject {
        try ComposeParser.parse(yaml, projectNameFallback: "p").project
    }

    @Test("a minimal service maps to a deterministic run argv")
    func minimalRunArgv() throws {
        let proj = try project("""
        name: demo
        services:
          web:
            image: nginx
            environment:
              A: "1"
            ports:
              - "8080:80"
        """)
        let result = ComposeTranslate.runArgs(serviceName: "web", project: proj)
        #expect(result.argv == [
            "run", "-d",
            "--name", "demo-web",
            "--label", "com.composeforcontainer.project=demo",
            "--label", "com.composeforcontainer.service=web",
            "-e", "A=1",
            "-p", "8080:80",
            "nginx",
        ])
        #expect(result.warnings.isEmpty)
    }

    @Test("cidfile and named volume / network mounts")
    func mountsAndCidfile() throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: postgres
            volumes:
              - dbdata:/var/lib/postgresql/data
            networks: [backend]
        networks:
          backend:
            internal: true
        volumes:
          dbdata:
        """)
        let result = ComposeTranslate.runArgs(
            serviceName: "db", project: proj,
            options: TranslateOptions(cidfilePath: "/tmp/db.cid"))
        #expect(containsSlice(result.argv, ["--cidfile", "/tmp/db.cid"]))
        #expect(containsSlice(result.argv, ["--mount", "type=volume,source=dbdata,target=/var/lib/postgresql/data"]))
        #expect(containsSlice(result.argv, ["--network", "backend"]))
    }

    @Test("prerequisites cover networks and volumes, excluding external")
    func prerequisites() throws {
        let proj = try project("""
        name: demo
        services:
          db:
            image: postgres
            volumes: [dbdata:/data, cache:/cache]
            networks: [backend]
        networks:
          backend:
            internal: true
        volumes:
          dbdata:
          cache:
            external: true
        """)
        let prereqs = ComposeTranslate.prerequisites(proj)
        #expect(prereqs.contains(.network(name: "backend", argv: ["network", "create", "backend", "--internal"])))
        #expect(prereqs.contains(.volume(name: "dbdata", argv: ["volume", "create", "dbdata"])))
        // external volume must not be created
        #expect(!prereqs.contains(.volume(name: "cache", argv: ["volume", "create", "cache"])))
    }

    @Test("build args derive a deterministic tag")
    func buildArgs() throws {
        let proj = try project("""
        name: demo
        services:
          api:
            build:
              context: ./api
              dockerfile: Dockerfile.prod
              args:
                VERSION: "2"
              target: runtime
        """)
        let build = try #require(ComposeTranslate.buildArgs(serviceName: "api", project: proj))
        #expect(build.tag == "demo-api:compose")
        #expect(build.argv == [
            "build", "-t", "demo-api:compose",
            "-f", "Dockerfile.prod",
            "--build-arg", "VERSION=2",
            "--target", "runtime",
            "./api",
        ])
        // run uses the derived tag as the image when no image is set.
        let run = ComposeTranslate.runArgs(serviceName: "api", project: proj)
        #expect(run.argv.contains("demo-api:compose"))
    }

    @Test("multi-element entrypoint folds extras into command")
    func entrypointFolding() throws {
        let proj = try project("""
        services:
          a:
            image: x
            entrypoint: ["/bin/sh", "-c"]
            command: "echo hi"
        """)
        let result = ComposeTranslate.runArgs(serviceName: "a", project: proj)
        #expect(containsSlice(result.argv, ["--entrypoint", "/bin/sh"]))
        // tail: image, folded entrypoint extra, then tokenized command
        #expect(Array(result.argv.suffix(4)) == ["x", "-c", "echo", "hi"])
        #expect(result.warnings.contains { if case .emulated = $0.kind { return true } else { return false } })
    }

    @Test("memory and cpu limits map and normalize")
    func resourceLimits() throws {
        let proj = try project("""
        services:
          a:
            image: x
            deploy:
              resources:
                limits:
                  cpus: "0.5"
                  memory: 512m
        """)
        let result = ComposeTranslate.runArgs(serviceName: "a", project: proj)
        #expect(containsSlice(result.argv, ["-c", "0.5"]))
        #expect(containsSlice(result.argv, ["-m", "512M"]))
    }

    @Test("engine-gap warnings: restart, healthcheck, multi-network, privileged port")
    func engineGapWarnings() throws {
        let proj = try project("""
        services:
          a:
            image: x
            restart: always
            ports:
              - "80:80"
            networks: [front, back]
            healthcheck:
              test: ["CMD", "true"]
        """)
        let result = ComposeTranslate.runArgs(serviceName: "a", project: proj)
        let gaps = Set(result.warnings.compactMap { warning -> Warning.EngineGap? in
            if case .engineGap(let gap) = warning.kind { return gap } else { return nil }
        })
        #expect(gaps.isSuperset(of: [.restart, .healthcheck, .multiNetwork, .privilegedPort]))
        // only the first network is attached
        #expect(containsSlice(result.argv, ["--network", "front"]))
        #expect(!result.argv.contains("back"))
    }

    @Test("a service with neither image nor build is blocking")
    func missingImageIsBlocking() throws {
        let proj = try project("""
        services:
          a:
            environment:
              X: "1"
        """)
        let result = ComposeTranslate.runArgs(serviceName: "a", project: proj)
        #expect(result.warnings.contains { $0.severity == .blocking })
    }

    @Test("baseDirectory resolves relative build/bind/env_file paths; leaves absolute & named")
    func baseDirectoryResolution() throws {
        let proj = try project("""
        name: demo
        services:
          api:
            build:
              context: ./api
              dockerfile: Dockerfile
            env_file: ./env/api.env
            volumes:
              - ./src:/var/www/html
              - /etc/hosts:/host-hosts
              - data:/data
        volumes:
          data:
        """)
        let opts = TranslateOptions(baseDirectory: "/abs/base")
        let run = ComposeTranslate.runArgs(serviceName: "api", project: proj, options: opts)
        // relative bind → absolutized against the base dir
        #expect(containsSlice(run.argv, ["--mount", "type=bind,source=/abs/base/src,target=/var/www/html"]))
        // absolute bind → unchanged
        #expect(containsSlice(run.argv, ["--mount", "type=bind,source=/etc/hosts,target=/host-hosts"]))
        // named volume → not treated as a path
        #expect(containsSlice(run.argv, ["--mount", "type=volume,source=data,target=/data"]))
        // env_file → absolutized
        #expect(containsSlice(run.argv, ["--env-file", "/abs/base/env/api.env"]))

        let build = try #require(ComposeTranslate.buildArgs(serviceName: "api", project: proj, baseDirectory: "/abs/base"))
        #expect(build.argv.last == "/abs/base/api")                       // context
        #expect(containsSlice(build.argv, ["-f", "/abs/base/api/Dockerfile"]))  // dockerfile vs context
    }

    @Test("baseDirectory nil leaves paths verbatim (back-compat)")
    func baseDirectoryNilVerbatim() throws {
        let proj = try project("""
        services:
          a:
            image: x
            volumes: ["./src:/work"]
        """)
        let run = ComposeTranslate.runArgs(serviceName: "a", project: proj)
        #expect(containsSlice(run.argv, ["--mount", "type=bind,source=./src,target=/work"]))
    }

    @Test("hostGateway is injected as HOST_GATEWAY env into the run")
    func hostGatewayInjection() throws {
        let proj = try project("services:\n  a:\n    image: x\n")
        let opts = TranslateOptions(hostGateway: "192.168.64.1")
        let run = ComposeTranslate.runArgs(serviceName: "a", project: proj, options: opts)
        #expect(containsSlice(run.argv, ["-e", "HOST_GATEWAY=192.168.64.1"]))
        // not injected when unset
        let bare = ComposeTranslate.runArgs(serviceName: "a", project: proj)
        #expect(!bare.argv.contains("HOST_GATEWAY=192.168.64.1"))
    }

    @Test("preflight flags a bind source that is a file, not a directory")
    func preflightBindFile() throws {
        let proj = try project("""
        services:
          web:
            image: nginx
            volumes:
              - ./conf/site.conf:/etc/nginx/conf.d/site.conf
              - ./html:/usr/share/nginx/html
        """)
        let opts = TranslateOptions(baseDirectory: "/base")
        let warnings = ComposeTranslate.preflightWarnings(project: proj, options: opts) { path in
            path == "/base/conf/site.conf" ? .file : .directory
        }
        #expect(warnings.count == 1)
        #expect(warnings.first?.service == "web")
        if case .engineGap(.bindFileNotDirectory) = warnings.first?.kind {} else {
            Issue.record("expected bindFileNotDirectory warning")
        }
    }

    // MARK: helper

    private func containsSlice(_ array: [String], _ slice: [String]) -> Bool {
        guard !slice.isEmpty, array.count >= slice.count else { return false }
        for start in 0...(array.count - slice.count) where Array(array[start..<start + slice.count]) == slice {
            return true
        }
        return false
    }
}
