import ComposeModel
import Testing

@testable import ComposeTranslate

/// The fingerprint decides whether `up` leaves a service alone, so what it does and
/// does not take account of is the whole design.
@Suite("Config hash")
struct ComposeHashTests {

    private let base = ["run", "-d", "--name", "demo-web", "nginx"]

    @Test("the same configuration and image hash the same")
    func stable() {
        #expect(ComposeHash.digest(argv: base, imageID: "sha256:aaa")
            == ComposeHash.digest(argv: base, imageID: "sha256:aaa"))
    }

    @Test("a changed argument changes the hash")
    func argvSensitivity() {
        #expect(ComposeHash.digest(argv: base, imageID: "x")
            != ComposeHash.digest(argv: base + ["-p", "8080:80"], imageID: "x"))
    }

    /// `image: nginx:latest` can mean a different image tomorrow, and a `build:`
    /// service's image changes with its Dockerfile. Either must force a recreate.
    @Test("a changed image changes the hash even when the arguments do not")
    func imageSensitivity() {
        #expect(ComposeHash.digest(argv: base, imageID: "sha256:aaa")
            != ComposeHash.digest(argv: base, imageID: "sha256:bbb"))
        #expect(ComposeHash.digest(argv: base, imageID: nil)
            != ComposeHash.digest(argv: base, imageID: "sha256:aaa"))
    }

    @Test("arguments cannot be re-split into the same hash")
    func noBoundaryCollisions() {
        #expect(ComposeHash.digest(argv: ["ab", "c"], imageID: nil)
            != ComposeHash.digest(argv: ["a", "bc"], imageID: nil))
    }

    // MARK: - what must not be hashed

    @Test("--cidfile is dropped: its path is new every run")
    func cidfileExcluded() {
        let withCidfile = ["run", "--cidfile", "/tmp/abc123", "--name", "demo-web", "nginx"]
        let without = ["run", "--name", "demo-web", "nginx"]
        #expect(ComposeHash.normalize(withCidfile, positionalIndex: .max, excludingInjectedGateway: true) == without)
    }

    @Test("the config-hash label is dropped: it is the output, not an input")
    func ownLabelExcluded() {
        let argv = ["run", "--label", "\(ComposeLabels.configHash)=deadbeef", "--name", "x", "nginx"]
        #expect(ComposeHash.normalize(argv, positionalIndex: .max, excludingInjectedGateway: true)
            == ["run", "--name", "x", "nginx"])
        // other labels are configuration and stay
        let kept = ["run", "--label", "\(ComposeLabels.project)=demo", "nginx"]
        #expect(ComposeHash.normalize(kept, positionalIndex: .max, excludingInjectedGateway: true) == kept)
    }

    @Test("the injected HOST_GATEWAY is dropped: the gateway moves on its own")
    func injectedGatewayExcluded() {
        let argv = ["run", "-e", "HOST_GATEWAY=192.168.64.1", "-e", "TZ=UTC", "nginx"]
        #expect(ComposeHash.normalize(argv, positionalIndex: .max, excludingInjectedGateway: true)
            == ["run", "-e", "TZ=UTC", "nginx"])
        // A gateway address change must not recreate the stack.
        let moved = ["run", "-e", "HOST_GATEWAY=192.168.65.1", "-e", "TZ=UTC", "nginx"]
        #expect(ComposeHash.digest(
            argv: ComposeHash.normalize(argv, positionalIndex: .max, excludingInjectedGateway: true), imageID: "x")
            == ComposeHash.digest(
                argv: ComposeHash.normalize(moved, positionalIndex: .max, excludingInjectedGateway: true), imageID: "x"))
    }

    /// …but a HOST_GATEWAY the compose file sets itself is configuration, and
    /// changing it should recreate.
    @Test("a declared HOST_GATEWAY is kept")
    func declaredGatewayKept() {
        let argv = ["run", "-e", "HOST_GATEWAY=10.0.0.1", "nginx"]
        #expect(ComposeHash.normalize(argv, positionalIndex: .max, excludingInjectedGateway: false) == argv)
    }

    @Test("a trailing flag with no value is not swallowed")
    func trailingFlag() {
        #expect(ComposeHash.normalize(
            ["run", "--cidfile"], positionalIndex: .max, excludingInjectedGateway: true) == ["run"])
        #expect(ComposeHash.normalize(
            ["run", "--label"], positionalIndex: .max, excludingInjectedGateway: true)
            == ["run", "--label"])
    }

    /// The exclusions apply to the options this plugin emits, never to the command
    /// the service runs — where `--cidfile` is the service's own argument.
    @Test("tokens inside the container's own command are never stripped")
    func positionalsAreOpaque() {
        let argv = ["run", "-d", "busybox", "myapp", "--cidfile", "/var/run/a.pid"]
        #expect(ComposeHash.normalize(argv, positionalIndex: 2, excludingInjectedGateway: true) == argv)
        // …so editing that path recreates, as it must.
        let edited = ["run", "-d", "busybox", "myapp", "--cidfile", "/var/run/b.pid"]
        #expect(ComposeHash.digest(
            argv: ComposeHash.normalize(argv, positionalIndex: 2, excludingInjectedGateway: true),
            imageID: "x")
            != ComposeHash.digest(
                argv: ComposeHash.normalize(edited, positionalIndex: 2, excludingInjectedGateway: true),
                imageID: "x"))
    }

    @Test("the boundary from runArgs points at the image")
    func positionalIndexPointsAtTheImage() throws {
        let proj = try ComposeParser.parse("""
            name: demo
            services:
              web:
                image: nginx
                command: ["sh", "-c", "true"]
            """, projectNameFallback: "p").project
        let result = ComposeTranslate.runArgs(serviceName: "web", project: proj)
        #expect(result.argv[result.positionalIndex] == "nginx")
    }
}

@Suite("Config hash in argv")
struct ConfigHashArgvTests {

    private func project() throws -> ComposeProject {
        try ComposeParser.parse("""
            name: demo
            services:
              web:
                image: nginx
                command: ["nginx", "-g", "daemon off;"]
            """, projectNameFallback: "p").project
    }

    /// The argv ends with the image and the command, so the label has to go in the
    /// options block. Appending it made `--label` an argument to nginx.
    @Test("the label lands before the image, not after the command")
    func labelPositionedWithTheOptions() throws {
        let argv = ComposeTranslate.runArgs(
            serviceName: "web", project: try project(),
            options: TranslateOptions(configHash: "abc123")).argv
        let label = try #require(argv.firstIndex(of: "\(ComposeLabels.configHash)=abc123"))
        let image = try #require(argv.firstIndex(of: "nginx"))
        #expect(label < image)
        #expect(argv.last == "daemon off;")
    }

    /// Which is what lets the orchestrator translate twice — once to hash, once to
    /// run — and get the same fingerprint either way.
    @Test("hashing the stamped argv gives the same answer as hashing the plain one")
    func stampingDoesNotChangeTheHash() throws {
        let proj = try project()
        let plain = ComposeTranslate.runArgs(serviceName: "web", project: proj)
        let hash = ComposeHash.digest(
            argv: ComposeHash.normalize(
                plain.argv, positionalIndex: plain.positionalIndex, excludingInjectedGateway: true),
            imageID: "x")
        let stamped = ComposeTranslate.runArgs(
            serviceName: "web", project: proj, options: TranslateOptions(configHash: hash))
        #expect(ComposeHash.digest(
            argv: ComposeHash.normalize(
                stamped.argv, positionalIndex: stamped.positionalIndex, excludingInjectedGateway: true),
            imageID: "x") == hash)
    }
}
