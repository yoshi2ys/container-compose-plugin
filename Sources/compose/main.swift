import ComposeCLICore
import Foundation

/// `container compose …` — a CLI plugin that runs multi-container apps from a
/// compose file by driving the `container` CLI. Everything lives in
/// `ComposeCLICore`; this shim only supplies the real process environment.
@main
struct ComposeMain {
    static func main() async {
        let code = await ComposeCLI.run(.live(arguments: Array(CommandLine.arguments.dropFirst())))
        exit(code)
    }
}
