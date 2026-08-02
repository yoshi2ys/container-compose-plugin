import ContainerEngine
import EngineTestSupport
import Testing

@testable import ComposeCLICore

@Suite("ps table")
struct ContainerTableTests {

    @Test("columns line up when a cell contains a non-BMP character")
    func widePaddingIsGraphemeBased() {
        let rendered = ContainerTable.render([
            composeContainer(project: "demo", service: "web", name: "web-🐳", image: "nginx"),
            composeContainer(project: "demo", service: "db", name: "db", image: "mysql"),
        ])
        // The emoji must survive: measuring in graphemes and padding in UTF-16 units
        // truncates it into a lone surrogate.
        #expect(rendered.contains("web-🐳"))
        // …and the column after it starts at the same offset on both rows.
        let lines = rendered.split(separator: "\n").map(String.init)
        func offset(of needle: String, in line: String) -> Int? {
            line.range(of: needle).map { line.distance(from: line.startIndex, to: $0.lowerBound) }
        }
        #expect(offset(of: "nginx", in: lines[1]) == offset(of: "mysql", in: lines[2]))
    }

    @Test("an empty PORTS cell leaves no trailing whitespace")
    func noRaggedTail() {
        let rendered = ContainerTable.render([
            composeContainer(project: "demo", service: "db", image: "mysql")
        ])
        #expect(rendered.split(separator: "\n").allSatisfy { !$0.hasSuffix(" ") })
    }
}
