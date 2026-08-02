import Foundation

/// Interleaves the log lines of several services onto one stream.
///
/// A lock-guarded class, not an actor, and deliberately so: lines arrive from a
/// reader thread per service, and hopping them onto an actor would mean either
/// awaiting inside a synchronous callback (impossible) or spawning a task per
/// line (unordered — a stack trace would come out shuffled, and lines still in
/// flight would be lost when the process exits). Writing under a lock, on the
/// thread that read the line, keeps each service's output in order and loses
/// nothing.
///
/// Everything else it does — the `service |` prefix, the per-service colour, the
/// column width — is presentation.
final class LogMultiplexer: @unchecked Sendable {
    private let lock = NSLock()
    private let write: @Sendable (String) -> Void
    private let width: Int
    private let colours: [String: String]

    /// The eight ANSI foreground colours that read well on both light and dark
    /// terminals; assigned to services in the order the compose file lists them, so a
    /// service keeps its colour across runs.
    private static let palette = [
        "\u{1B}[36m", "\u{1B}[33m", "\u{1B}[32m", "\u{1B}[35m",
        "\u{1B}[34m", "\u{1B}[31m", "\u{1B}[96m", "\u{1B}[93m",
    ]
    private static let reset = "\u{1B}[0m"

    /// - Parameter colour: false when stdout is not a terminal, so a redirected log
    ///   does not collect escape sequences.
    init(services: [String], colour: Bool, write: @escaping @Sendable (String) -> Void) {
        self.write = write
        self.width = services.map(\.count).max() ?? 0
        var assigned: [String: String] = [:]
        if colour {
            for (index, service) in services.enumerated() {
                assigned[service] = Self.palette[index % Self.palette.count]
            }
        }
        self.colours = assigned
    }

    func line(_ service: String, _ text: String) {
        // Padded by grapheme count; `String.padding` measures UTF-16 and would
        // truncate a name containing an emoji.
        let padded = service + String(repeating: " ", count: max(0, width - service.count))
        let rendered = colours[service].map { "\($0)\(padded) |\(Self.reset) \(text)\n" }
            ?? "\(padded) | \(text)\n"
        lock.withLock { write(rendered) }
    }
}
