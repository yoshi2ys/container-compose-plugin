import Foundation

// MARK: - Environment / labels (list "KEY=VAL" or map)

public struct EnvMap: Decodable, Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let key: String
        /// `nil` = inherit from host (the bare `- KEY` / `KEY:` form).
        public let value: String?
        public init(key: String, value: String?) { self.key = key; self.value = value }
    }

    public var entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let dict = try? c.decode([String: YAMLScalar].self) {
            entries = dict.map { Entry(key: $0.key, value: $0.value.stringValue) }
                .sorted { $0.key < $1.key }
        } else if let list = try? c.decode([String].self) {
            entries = list.map { item in
                let (key, value) = splitKeyValue(item)
                return Entry(key: key, value: value)
            }
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "environment must be a mapping or a list of KEY=VAL strings"))
        }
    }
}

public struct LabelPair: Sendable, Equatable {
    public let key: String
    public let value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

// MARK: - command / entrypoint (string or [string])

public enum CommandSpec: Decodable, Sendable, Equatable {
    case shell(String)
    case exec([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .shell(s)
        } else {
            self = .exec(try c.decode([String].self))
        }
    }
}

// MARK: - build (string path or mapping)

public struct BuildSpec: Decodable, Sendable, Equatable {
    public var context: String
    public var dockerfile: String?
    public var args: EnvMap
    public var target: String?

    public init(context: String, dockerfile: String? = nil, args: EnvMap = EnvMap(), target: String? = nil) {
        self.context = context; self.dockerfile = dockerfile; self.args = args; self.target = target
    }

    enum CodingKeys: String, CodingKey { case context, dockerfile, args, target }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(context: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            context: try c.decodeIfPresent(String.self, forKey: .context) ?? ".",
            dockerfile: try c.decodeIfPresent(String.self, forKey: .dockerfile),
            args: try c.decodeIfPresent(EnvMap.self, forKey: .args) ?? EnvMap(),
            target: try c.decodeIfPresent(String.self, forKey: .target))
    }
}

// MARK: - ports (short "ip:host:container/proto" or long mapping)

public struct PortMapping: Decodable, Sendable, Equatable {
    public var hostIP: String?
    public var published: String?      // host port; nil = runtime-assigned
    public var target: String          // container port (kept as string to allow ranges)
    public var proto: String?          // tcp/udp
    public var isRange: Bool

    public init(hostIP: String? = nil, published: String?, target: String, proto: String? = nil, isRange: Bool = false) {
        self.hostIP = hostIP; self.published = published; self.target = target; self.proto = proto; self.isRange = isRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let scalar = try? c.decode(YAMLScalar.self), let s = scalar.stringValue {
            self = try PortMapping(short: s, codingPath: decoder.codingPath)
        } else {
            let l = try LongForm(from: decoder)
            let pub = l.published?.stringValue
            let tgt = l.target.stringValue ?? "0"
            self.init(hostIP: l.hostIP, published: pub, target: tgt, proto: l.proto,
                      isRange: (pub?.contains("-") ?? false) || tgt.contains("-"))
        }
    }

    init(short: String, codingPath: [CodingKey]) throws {
        var body = short
        var proto: String? = nil
        if let slash = body.firstIndex(of: "/") {
            proto = String(body[body.index(after: slash)...])
            body = String(body[..<slash])
        }

        // Bracketed IPv6 host, e.g. "[::1]:8080:80" — pull the host out before
        // splitting on ":" so the address's own colons don't confuse the parse.
        var hostIP: String?
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            hostIP = String(body[body.index(after: body.startIndex)..<close])
            body = String(body[body.index(after: close)...])
            if body.hasPrefix(":") { body.removeFirst() }
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let published: String?, target: String
        switch parts.count {
        case 1:
            published = nil; target = parts[0]
        case 2:
            published = parts[0]; target = parts[1]
        case 3 where hostIP == nil:
            hostIP = parts[0]; published = parts[1]; target = parts[2]
        default:
            // Unbracketed IPv6 host or extra colons: the last two fields are
            // published:target; anything before is the host. Degrade rather than
            // fail the whole file's parse.
            guard parts.count >= 2 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath,
                    debugDescription: "invalid port mapping '\(short)'"))
            }
            target = parts[parts.count - 1]
            published = parts[parts.count - 2]
            if hostIP == nil { hostIP = parts[0..<(parts.count - 2)].joined(separator: ":") }
        }
        let isRange = (published?.contains("-") ?? false) || target.contains("-")
        self.init(hostIP: hostIP, published: published, target: target, proto: proto, isRange: isRange)
    }

    struct LongForm: Decodable {
        var hostIP: String?
        var published: YAMLScalar?
        var target: YAMLScalar
        var proto: String?
        enum CodingKeys: String, CodingKey {
            case target, published
            case proto = "protocol"
            case hostIP = "host_ip"
        }
    }
}

// MARK: - volumes (short "src:dst:ro" or long mapping)

public enum VolumeMount: Decodable, Sendable, Equatable {
    case bind(source: String, target: String, readOnly: Bool)
    case named(volume: String, target: String, readOnly: Bool)
    case anonymous(target: String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = try Self.parseShort(s, codingPath: decoder.codingPath)
            return
        }
        let l = try LongForm(from: decoder)
        let ro = l.readOnly ?? false
        switch l.type {
        case "bind": self = .bind(source: l.source ?? "", target: l.target, readOnly: ro)
        case "volume": self = .named(volume: l.source ?? "", target: l.target, readOnly: ro)
        default:
            if let src = l.source { self = Self.classify(source: src, target: l.target, readOnly: ro) }
            else { self = .anonymous(target: l.target) }
        }
    }

    static func parseShort(_ s: String, codingPath: [CodingKey]) throws -> VolumeMount {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return .anonymous(target: parts[0])
        case 2: return classify(source: parts[0], target: parts[1], readOnly: false)
        case 3: return classify(source: parts[0], target: parts[1], readOnly: parts[2].contains("ro"))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "invalid volume mount '\(s)'"))
        }
    }

    /// A source that looks like a filesystem path is a bind; a bare token is a named volume.
    static func classify(source: String, target: String, readOnly: Bool) -> VolumeMount {
        if source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~") {
            return .bind(source: source, target: target, readOnly: readOnly)
        }
        return .named(volume: source, target: target, readOnly: readOnly)
    }

    struct LongForm: Decodable {
        var type: String
        var source: String?
        var target: String
        var readOnly: Bool?
        enum CodingKeys: String, CodingKey {
            case type, source, target
            case readOnly = "read_only"
        }
    }
}

// MARK: - depends_on (list or map with conditions)

public enum DependsCondition: String, Sendable, Equatable {
    case started = "service_started"
    case healthy = "service_healthy"
    case completedSuccessfully = "service_completed_successfully"
}

public struct Dependency: Sendable, Equatable {
    public let service: String
    public let condition: DependsCondition
    public init(service: String, condition: DependsCondition) {
        self.service = service; self.condition = condition
    }
}

struct DependsEntry: Decodable {
    let condition: DependsCondition
    enum CodingKeys: String, CodingKey { case condition }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .condition)
        condition = raw.flatMap(DependsCondition.init(rawValue:)) ?? .started
    }
}

// MARK: - service-level networks (list or map with aliases)

public struct ServiceNetworkAttach: Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    public init(name: String, aliases: [String]) { self.name = name; self.aliases = aliases }
}

struct NetworkAttachOptions: Decodable {
    var aliases: [String]
    enum CodingKeys: String, CodingKey { case aliases }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
    }
}

struct ServiceNetworksMap: Decodable {
    let attaches: [ServiceNetworkAttach]
    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([String].self) {
            attaches = list.map { ServiceNetworkAttach(name: $0, aliases: []) }
            return
        }
        let c = try decoder.container(keyedBy: DynamicKey.self)
        attaches = c.allKeys.map { key in
            let opts = try? c.decodeIfPresent(NetworkAttachOptions.self, forKey: key)
            return ServiceNetworkAttach(name: key.stringValue, aliases: opts?.aliases ?? [])
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - restart

public enum RestartPolicy: Sendable, Equatable, Decodable {
    case no
    case always
    case unlessStopped
    case onFailure(maxRetries: Int?)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "always": self = .always
        case "unless-stopped": self = .unlessStopped
        case "no": self = .no
        default:
            if raw.hasPrefix("on-failure") {
                let parts = raw.split(separator: ":")
                self = .onFailure(maxRetries: parts.count > 1 ? Int(parts[1]) : nil)
            } else {
                self = .no
            }
        }
    }
}

// MARK: - healthcheck

public struct Healthcheck: Decodable, Sendable, Equatable {
    /// Normalized `test`; first element is the directive (`CMD`, `CMD-SHELL`, `NONE`).
    public var test: [String]
    public var interval: String?
    public var timeout: String?
    public var retries: Int?
    public var startPeriod: String?
    public var disable: Bool?

    enum CodingKeys: String, CodingKey {
        case test, interval, timeout, retries, disable
        case startPeriod = "start_period"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .test) {
            test = ["CMD-SHELL", s]
        } else if let arr = try? c.decodeIfPresent([String].self, forKey: .test) {
            test = arr
        } else {
            test = []
        }
        interval = try c.decodeIfPresent(String.self, forKey: .interval)
        timeout = try c.decodeIfPresent(String.self, forKey: .timeout)
        retries = try c.decodeIfPresent(Int.self, forKey: .retries)
        startPeriod = try c.decodeIfPresent(String.self, forKey: .startPeriod)
        disable = try c.decodeIfPresent(Bool.self, forKey: .disable)
    }
}

// MARK: - deploy.resources.limits

public struct DeploySpec: Decodable, Sendable, Equatable {
    public var cpus: String?
    public var memory: String?

    enum CodingKeys: String, CodingKey { case resources }

    struct Resources: Decodable {
        var limits: Limits?
        struct Limits: Decodable {
            var cpus: String?
            var memory: String?
            enum CodingKeys: String, CodingKey { case cpus, memory }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                cpus = (try? c.decodeIfPresent(YAMLScalar.self, forKey: .cpus)).flatMap { $0.stringValue }
                memory = try c.decodeIfPresent(String.self, forKey: .memory)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let r = try c.decodeIfPresent(Resources.self, forKey: .resources)
        cpus = r?.limits?.cpus
        memory = r?.limits?.memory
    }
}
