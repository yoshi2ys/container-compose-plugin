import Foundation

/// One service from a compose file's `services:` map, normalized to clean shapes.
public struct Service: Decodable, Sendable, Equatable {
    public var image: String?
    public var build: BuildSpec?
    public var containerName: String?
    public var command: CommandSpec?
    public var entrypoint: CommandSpec?
    public var environment: EnvMap
    public var envFile: [String]
    public var ports: [PortMapping]
    public var volumes: [VolumeMount]
    public var dependsOn: [Dependency]
    public var networks: [ServiceNetworkAttach]
    public var restart: RestartPolicy?
    public var healthcheck: Healthcheck?
    public var deploy: DeploySpec?
    public var labels: [LabelPair]
    public var workingDir: String?
    public var user: String?
    public var capAdd: [String]
    public var capDrop: [String]
    public var dns: [String]
    public var dnsSearch: [String]
    public var profiles: [String]
    public var readOnly: Bool?
    public var tmpfs: [String]
    public var initProcess: Bool?
    public var platform: String?

    /// Keys present on this service that we do not support (populated by `ComposeParser`).
    public var unknownKeys: [String] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case image, build
        case containerName = "container_name"
        case command, entrypoint, environment
        case envFile = "env_file"
        case ports, volumes
        case dependsOn = "depends_on"
        case networks, restart, healthcheck, deploy, labels
        case workingDir = "working_dir"
        case user
        case capAdd = "cap_add"
        case capDrop = "cap_drop"
        case dns
        case dnsSearch = "dns_search"
        case profiles
        case readOnly = "read_only"
        case tmpfs
        case initProcess = "init"
        case platform
    }

    /// The set of compose keys this model understands (for unsupported-key detection).
    public static let knownKeys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        build = try c.decodeIfPresent(BuildSpec.self, forKey: .build)
        containerName = try c.decodeIfPresent(String.self, forKey: .containerName)
        command = try c.decodeIfPresent(CommandSpec.self, forKey: .command)
        entrypoint = try c.decodeIfPresent(CommandSpec.self, forKey: .entrypoint)
        environment = try c.decodeIfPresent(EnvMap.self, forKey: .environment) ?? EnvMap()
        envFile = try Self.stringOrArray(c, .envFile)
        ports = try c.decodeIfPresent([PortMapping].self, forKey: .ports) ?? []
        volumes = try c.decodeIfPresent([VolumeMount].self, forKey: .volumes) ?? []
        dependsOn = try Self.decodeDependsOn(c)
        networks = (try c.decodeIfPresent(ServiceNetworksMap.self, forKey: .networks))?.attaches ?? []
        restart = try c.decodeIfPresent(RestartPolicy.self, forKey: .restart)
        healthcheck = try c.decodeIfPresent(Healthcheck.self, forKey: .healthcheck)
        deploy = try c.decodeIfPresent(DeploySpec.self, forKey: .deploy)
        labels = try Self.decodeLabels(c)
        workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        capAdd = try c.decodeIfPresent([String].self, forKey: .capAdd) ?? []
        capDrop = try c.decodeIfPresent([String].self, forKey: .capDrop) ?? []
        dns = try Self.stringOrArray(c, .dns)
        dnsSearch = try Self.stringOrArray(c, .dnsSearch)
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles) ?? []
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly)
        tmpfs = try Self.stringOrArray(c, .tmpfs)
        initProcess = try c.decodeIfPresent(Bool.self, forKey: .initProcess)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
    }
}

// MARK: - polymorphic-key helpers

extension Service {
    /// A value that is either a single scalar or an array of scalars → `[String]`.
    static func stringOrArray(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> [String] {
        if let scalar = try? c.decodeIfPresent(YAMLScalar.self, forKey: key), let s = scalar.stringValue {
            return [s]
        }
        if let arr = try? c.decodeIfPresent([YAMLScalar].self, forKey: key) {
            return arr.compactMap(\.stringValue)
        }
        return []
    }

    static func decodeDependsOn(_ c: KeyedDecodingContainer<CodingKeys>) throws -> [Dependency] {
        if let list = try? c.decodeIfPresent([String].self, forKey: .dependsOn) {
            return list.map { Dependency(service: $0, condition: .started) }
        }
        if let map = try? c.decodeIfPresent([String: DependsEntry].self, forKey: .dependsOn) {
            return map.map { Dependency(service: $0.key, condition: $0.value.condition) }
                .sorted { $0.service < $1.service }
        }
        return []
    }

    static func decodeLabels(_ c: KeyedDecodingContainer<CodingKeys>) throws -> [LabelPair] {
        if let map = try? c.decodeIfPresent([String: YAMLScalar].self, forKey: .labels) {
            return map.map { LabelPair(key: $0.key, value: $0.value.stringValue ?? "") }
                .sorted { $0.key < $1.key }
        }
        if let list = try? c.decodeIfPresent([String].self, forKey: .labels) {
            return list.map { item in
                let (key, value) = splitKeyValue(item)
                return LabelPair(key: key, value: value ?? "")
            }
        }
        return []
    }
}
