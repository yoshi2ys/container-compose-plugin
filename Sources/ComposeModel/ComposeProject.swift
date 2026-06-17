import Foundation

/// A parsed compose file: the project name plus its services and top-level
/// network / volume definitions.
public struct ComposeProject: Decodable, Sendable, Equatable {
    public var name: String?
    public var services: [String: Service]
    public var networks: [String: NetworkDef]
    public var volumes: [String: VolumeDef]

    public init(name: String? = nil,
                services: [String: Service] = [:],
                networks: [String: NetworkDef] = [:],
                volumes: [String: VolumeDef] = [:]) {
        self.name = name
        self.services = services
        self.networks = networks
        self.volumes = volumes
    }

    enum CodingKeys: String, CodingKey { case name, services, networks, volumes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        services = try c.decodeIfPresent([String: Service].self, forKey: .services) ?? [:]
        networks = (try c.decodeIfPresent(NullableMap<NetworkDef>.self, forKey: .networks))?.values ?? [:]
        volumes = (try c.decodeIfPresent(NullableMap<VolumeDef>.self, forKey: .volumes))?.values ?? [:]
    }

    /// Service names in a deterministic order (the underlying map is unordered).
    public var serviceNames: [String] { services.keys.sorted() }
}

public struct NetworkDef: Decodable, Sendable, Equatable, DefaultConstructible {
    /// Externally managed; must not be created by us.
    public var external: Bool
    public var subnet: String?
    public var internalOnly: Bool

    public init() { external = false; subnet = nil; internalOnly = false }

    enum CodingKeys: String, CodingKey {
        case external, subnet
        case internalOnly = "internal"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        external = (try? c.decodeIfPresent(Bool.self, forKey: .external)) ?? false
        internalOnly = (try? c.decodeIfPresent(Bool.self, forKey: .internalOnly)) ?? false
        subnet = (try? c.decodeIfPresent(String.self, forKey: .subnet)) ?? nil
    }
}

public struct VolumeDef: Decodable, Sendable, Equatable, DefaultConstructible {
    /// Externally managed; must not be created by us.
    public var external: Bool

    public init() { external = false }

    enum CodingKeys: String, CodingKey { case external }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        external = (try? c.decodeIfPresent(Bool.self, forKey: .external)) ?? false
    }
}
