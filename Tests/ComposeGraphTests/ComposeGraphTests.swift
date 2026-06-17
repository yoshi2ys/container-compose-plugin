import Testing
import ComposeModel
@testable import ComposeGraph

@Suite("Dependency graph")
struct ComposeGraphTests {

    private func plan(_ yaml: String, profiles: Set<String> = []) throws -> StartupPlan {
        let project = try ComposeParser.parse(yaml, projectNameFallback: "p").project
        switch ComposeGraph.startupPlan(project, activeProfiles: profiles) {
        case .success(let p): return p
        case .failure(let e): throw e
        }
    }

    @Test("linear chain orders into single-service waves")
    func linearChain() throws {
        let yaml = """
        services:
          a:
            image: x
          b:
            image: x
            depends_on: [a]
          c:
            image: x
            depends_on: [b]
        """
        let p = try plan(yaml)
        #expect(p.waves == [["a"], ["b"], ["c"]])
        #expect(p.shutdownOrder == ["c", "b", "a"])
    }

    @Test("independent services share one wave, sorted deterministically")
    func independentServices() throws {
        let yaml = """
        services:
          c:
            image: x
          a:
            image: x
          b:
            image: x
        """
        let p = try plan(yaml)
        #expect(p.waves == [["a", "b", "c"]])
    }

    @Test("diamond dependency")
    func diamond() throws {
        let yaml = """
        services:
          base:
            image: x
          left:
            image: x
            depends_on: [base]
          right:
            image: x
            depends_on: [base]
          top:
            image: x
            depends_on: [left, right]
        """
        let p = try plan(yaml)
        #expect(p.waves == [["base"], ["left", "right"], ["top"]])
        #expect(p.shutdownOrder == ["top", "right", "left", "base"])
    }

    @Test("cycle is detected")
    func cycle() throws {
        let yaml = """
        services:
          a:
            image: x
            depends_on: [b]
          b:
            image: x
            depends_on: [a]
        """
        let project = try ComposeParser.parse(yaml, projectNameFallback: "p").project
        let result = ComposeGraph.startupPlan(project)
        #expect(result == .failure(.cycle(["a", "b"])))
    }

    @Test("missing dependency is an error")
    func missingDependency() throws {
        let yaml = """
        services:
          a:
            image: x
            depends_on: [ghost]
        """
        let project = try ComposeParser.parse(yaml, projectNameFallback: "p").project
        let result = ComposeGraph.startupPlan(project)
        #expect(result == .failure(.missingDependency(service: "a", dependency: "ghost")))
    }

    @Test("inactive profile excludes a service and drops its edge")
    func profileExclusion() throws {
        let yaml = """
        services:
          app:
            image: x
            depends_on: [debugger]
          debugger:
            image: x
            profiles: [debug]
        """
        // Without the profile: debugger excluded, its edge dropped, app runs alone.
        let withoutProfile = try plan(yaml)
        #expect(withoutProfile.waves == [["app"]])

        // With the profile: debugger included and ordered before app.
        let withProfile = try plan(yaml, profiles: ["debug"])
        #expect(withProfile.waves == [["debugger"], ["app"]])
    }
}
