import CryptoKit
import Foundation

/// The fingerprint of a service's configuration, stamped on its container as a
/// label so the next `up` can tell whether anything actually changed.
///
/// Recreating a container that is already correct is not free: anything written
/// outside a named volume is lost, and a stack of long-running services is
/// restarted for nothing. The hash is what lets `up` leave those alone.
///
/// Pure — no filesystem, no time, no process. The caller supplies the image id.
public enum ComposeHash {

    /// Arguments that change between runs without the configuration changing.
    /// Hashing them would make every `up` recreate everything, which is the exact
    /// problem this is meant to solve.
    ///
    /// - `--cidfile <path>`: a fresh temporary path each run.
    /// - `-e HOST_GATEWAY=<ip>`: injected, and the gateway can move. Kept when the
    ///   compose file declares `HOST_GATEWAY` itself — that is configuration.
    /// - the config-hash label: it is the output, so it cannot also be an input.
    ///
    /// Only the option region is examined. Everything from `positionalIndex` on is
    /// the image and the container's own command, where a `--cidfile` or a
    /// `HOST_GATEWAY=` is the service's argument and changing it must recreate.
    public static func normalize(
        _ argv: [String], positionalIndex: Int, excludingInjectedGateway: Bool
    ) -> [String] {
        let boundary = min(max(0, positionalIndex), argv.count)
        var normalized: [String] = []
        var index = 0
        while index < boundary {
            let argument = argv[index]
            let value = index + 1 < argv.count ? argv[index + 1] : nil

            if argument == "--cidfile" {
                index += 2
                continue
            }
            if argument == "--label", let value, value.hasPrefix("\(ComposeLabels.configHash)=") {
                index += 2
                continue
            }
            if argument == "-e", excludingInjectedGateway, value?.hasPrefix("HOST_GATEWAY=") == true {
                index += 2
                continue
            }
            normalized.append(argument)
            index += 1
        }
        return normalized + argv[boundary...]
    }

    /// The hash of a normalized argv plus the id of the image it will run.
    ///
    /// The image id matters as much as the arguments: `image: nginx:latest` can mean
    /// a different image tomorrow, and a `build:` service's image changes whenever
    /// its Dockerfile or context does. Without it, `up` would skip a service whose
    /// image had moved underneath it.
    public static func digest(argv: [String], imageID: String?) -> String {
        var hasher = SHA256()
        // Length-prefixed so ["ab", "c"] and ["a", "bc"] cannot collide.
        for argument in argv + [imageID ?? ""] {
            let bytes = Data(argument.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
