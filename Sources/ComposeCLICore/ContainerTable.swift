import ContainerEngine

/// Renders `compose ps` as a column table.
///
/// The engine's own `container list` shows every container on the machine —
/// other projects, and the `buildkit` builder. This prints only what the caller
/// passes in, which is the project's own set.
enum ContainerTable {
    private static let headers = ["SERVICE", "NAME", "IMAGE", "STATE", "PORTS"]

    static func render(_ containers: [ContainerSummary]) -> String {
        let rows = containers.map { container in
            [
                container.composeService ?? "-",
                container.id,
                container.image,
                container.state,
                container.ports.map(\.description).joined(separator: ", "),
            ]
        }
        let widths = (0..<headers.count).map { column in
            ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        return ([headers] + rows).map { row in
            // The last column needs no padding, and an empty PORTS cell would
            // otherwise leave a ragged tail of spaces on the line.
            zip(row, widths).map(pad).joined(separator: "  ").trimmingTrailing(" ")
        }.joined(separator: "\n")
    }

    /// Pads by grapheme count, matching how `widths` is measured — `String.padding`
    /// counts UTF-16 units and truncates a cell containing an emoji.
    private static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }
}

extension String {
    fileprivate func trimmingTrailing(_ character: Character) -> String {
        var copy = self
        while copy.last == character { copy.removeLast() }
        return copy
    }
}
