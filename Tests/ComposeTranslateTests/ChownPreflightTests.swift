import ComposeModel
import Testing

@testable import ComposeTranslate

/// The bind-mount chown gap: Apple `container` accepts writes through a bind mount
/// but rejects ownership changes, so official database images die on the first line
/// of their entrypoint. The check is a pure function of the mount target and
/// `user:`, so it is covered exhaustively here rather than by example.
@Suite("chown preflight")
struct ChownPreflightTests {

    private func project(_ yaml: String) throws -> ComposeProject {
        try ComposeParser.parse(yaml, projectNameFallback: "p").project
    }

    private func warnings(_ yaml: String) throws -> [Warning] {
        ComposeTranslate.preflightWarnings(
            project: try project(yaml), options: TranslateOptions(baseDirectory: "/base")
        ) { _ in .directory }
        .filter { $0.kind == .engineGap(.bindChownRestricted) }
    }

    /// Every known data directory is flagged when bind-mounted with no `user:`.
    @Test(
        "a bind mount at a database data directory is flagged",
        arguments: ComposeTranslate.databaseDataDirectories.sorted() + ["/bitnami/mariadb"])
    func flagsDataDirectory(target: String) throws {
        let found = try warnings("""
            services:
              db:
                image: mysql
                volumes: ["./data:\(target)"]
            """)
        #expect(found.count == 1)
        #expect(found.first?.service == "db")
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("Operation not permitted") == true)
    }

    /// …and none of them is flagged once the service names a user, which is one of
    /// the two documented ways out.
    @Test(
        "an explicit user: silences it",
        arguments: ComposeTranslate.databaseDataDirectories.sorted() + ["/bitnami/mariadb"])
    func explicitUserSilences(target: String) throws {
        let found = try warnings("""
            services:
              db:
                image: mysql
                user: "1000:1000"
                volumes: ["./data:\(target)"]
            """)
        #expect(found.isEmpty)
    }

    /// …and neither is a named volume, which is the other way out.
    @Test(
        "a named volume is the fix, not the problem",
        arguments: ComposeTranslate.databaseDataDirectories.sorted())
    func namedVolumeNotFlagged(target: String) throws {
        let found = try warnings("""
            services:
              db:
                image: mysql
                volumes: ["dbdata:\(target)"]
            """)
        #expect(found.isEmpty)
    }

    @Test("an ordinary bind mount is not flagged")
    func ordinaryBindNotFlagged() throws {
        let found = try warnings("""
            services:
              web:
                image: nginx
                volumes: ["./src:/var/www/html", "./conf:/etc/nginx/conf.d"]
            """)
        #expect(found.isEmpty)
    }

    @Test("a trailing slash on the target does not hide the match")
    func trailingSlash() {
        #expect(ComposeTranslate.chownWarning(
            service: "db", source: "./data", target: "/var/lib/mysql/", user: nil) != nil)
    }

    @Test("a path merely under a data directory is not a data directory")
    func nestedPathNotFlagged() {
        #expect(ComposeTranslate.chownWarning(
            service: "db", source: "./conf", target: "/var/lib/mysql/conf.d", user: nil) == nil)
        #expect(ComposeTranslate.chownWarning(
            service: "db", source: "./x", target: "/var/lib/mysql-backup", user: nil) == nil)
    }

    /// The parameterized tests above iterate the constant itself, so a path dropped
    /// from it would silently drop out of the suite too. Pin the set literally.
    @Test("the data-directory table covers the paths the official images declare")
    func tableIsComplete() {
        #expect(ComposeTranslate.databaseDataDirectories == [
            "/var/lib/mysql",           // mysql, mariadb
            "/var/lib/postgresql/data", // postgres
            "/var/lib/mongodb",         // mongodb from a distro package
            "/data",                    // redis
            "/data/db",                 // the mongo image
            "/data/configdb",           // the mongo image
        ])
    }

    @Test(
        "root is not an escape: the entrypoints only chown when uid is 0",
        arguments: ["0", "0:0", "root", "root:root", ""])
    func rootUserStillWarns(user: String) throws {
        let found = try warnings("""
            services:
              db:
                image: mysql
                user: "\(user)"
                volumes: ["./data:/var/lib/mysql"]
            """)
        #expect(found.count == 1)
    }

    @Test(
        "the target is normalized before it is matched",
        arguments: ["/var/lib/mysql/", "//var/lib/mysql", "/var//lib/mysql", "/var/lib/./mysql"])
    func targetNormalization(target: String) {
        #expect(ComposeTranslate.chownWarning(
            service: "db", source: "./data", target: target, user: nil) != nil)
    }

    @Test("bitnami paths are matched with or without a trailing component")
    func bitnamiPaths() {
        for target in ["/bitnami", "/bitnami/", "/bitnami/mariadb", "/bitnami/postgresql/data"] {
            #expect(
                ComposeTranslate.chownWarning(
                    service: "db", source: "./data", target: target, user: nil) != nil,
                "expected '\(target)' to be flagged")
        }
    }

    @Test("a bind source that is a file gets one diagnosis, not two")
    func fileSourceSuppressesTheChownWarning() throws {
        let found = ComposeTranslate.preflightWarnings(
            project: try project("""
                services:
                  db:
                    image: mysql
                    volumes: ["./notes.txt:/data"]
                """),
            options: TranslateOptions(baseDirectory: "/base")
        ) { _ in .file }
        #expect(found.count == 1)
        #expect(found.first?.kind == .engineGap(.bindFileNotDirectory))
    }

    @Test("the warning names both ways out")
    func messageOffersBothWorkarounds() throws {
        let message = try #require(try warnings("""
            services:
              db:
                image: mariadb
                volumes: ["./data:/var/lib/mysql"]
            """).first?.message)
        #expect(message.contains("named volume"))
        #expect(message.contains("override the entrypoint"))
        // The image may never chown; the wording must not claim it will fail.
        #expect(message.contains("likely"))
    }
}
