import Foundation

public enum OpenClawProtocol {
    public static let currentVersion = 4
    public static let defaultGatewayPort = 18_789
    public static let preAuthMaximumBytes = 64 * 1024
}

public struct OpenClawRequestFrame<Params: Encodable & Sendable>: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let type = "req"
    public let id: String
    public let method: String
    public let params: Params

    public init(id: String, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Never render generic RPC params: request payloads may transitively contain
    /// bearer credentials, bootstrap tokens, signatures, or user content.
    public var description: String {
        "OpenClawRequestFrame(type: req, id: \(id), method: \(method), params: <redacted>)"
    }

    public var debugDescription: String { description }
}

public struct OpenClawGatewayClientIdentity: Sendable, Equatable {
    public let id: String
    public let mode: String
    public let platform: String
    public let deviceFamily: String

    public init(
        id: String,
        mode: String,
        platform: String,
        deviceFamily: String
    ) {
        self.id = id
        self.mode = mode
        self.platform = platform
        self.deviceFamily = deviceFamily
    }

    /// Generic authenticated backend identity used by the production AWL client.
    ///
    /// These are canonical OpenClaw protocol-v4 registry values. AWL deliberately
    /// does not claim the official OpenClaw iOS application identity.
    public static let backend = Self(
        id: "gateway-client",
        mode: "backend",
        platform: "ios",
        deviceFamily: "iphone"
    )

    /// Canonical identity for the read-only validation probe.
    public static let probe = Self(
        id: "openclaw-probe",
        mode: "probe",
        platform: "ios",
        deviceFamily: "iphone"
    )
}

public struct OpenClawConnectParams: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct Client: Encodable, Sendable {
        public let id: String
        public let version: String
        public let platform: String
        public let mode: String
        public let deviceFamily: String

        public init(
            identity: OpenClawGatewayClientIdentity,
            version: String
        ) {
            self.id = identity.id
            self.version = version
            self.platform = identity.platform
            self.mode = identity.mode
            self.deviceFamily = identity.deviceFamily
        }
    }

    public struct Auth: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let token: String?
        public let deviceToken: String?
        public let password: String?
        public let bootstrapToken: String?

        public init(
            token: String? = nil,
            deviceToken: String? = nil,
            password: String? = nil,
            bootstrapToken: String? = nil
        ) {
            self.token = token
            self.deviceToken = deviceToken
            self.password = password
            self.bootstrapToken = bootstrapToken
        }

        public var description: String {
            "Auth(token: \(token == nil ? "nil" : "<redacted>"), " +
            "deviceToken: \(deviceToken == nil ? "nil" : "<redacted>"), " +
            "password: \(password == nil ? "nil" : "<redacted>"), " +
            "bootstrapToken: \(bootstrapToken == nil ? "nil" : "<redacted>"))"
        }
        public var debugDescription: String { description }
    }

    public let minProtocol: Int
    public let maxProtocol: Int
    public let client: Client
    public let role: String
    public let scopes: [String]
    public let caps: [String]
    public let commands: [String]
    public let permissions: [String: Bool]
    public let auth: Auth?
    public let locale: String
    public let device: OpenClawDeviceProof?

    public init(
        version: String,
        clientIdentity: OpenClawGatewayClientIdentity = .backend,
        scopes: [String] = ["operator.read", "operator.write"],
        auth: Auth? = nil,
        locale: String = "en-US",
        device: OpenClawDeviceProof? = nil
    ) {
        self.minProtocol = OpenClawProtocol.currentVersion
        self.maxProtocol = OpenClawProtocol.currentVersion
        self.client = Client(identity: clientIdentity, version: version)
        self.role = "operator"
        self.scopes = scopes
        self.caps = []
        self.commands = []
        self.permissions = [:]
        self.auth = auth
        self.locale = locale
        self.device = device
    }

    /// Connect parameters transitively contain authentication material and a
    /// device proof. Diagnostics expose only non-secret shape/state.
    public var description: String {
        let authDescription = auth == nil ? "nil" : "<redacted>"
        let deviceDescription = device == nil ? "nil" : "<redacted>"
        return "OpenClawConnectParams(minProtocol: \(minProtocol), maxProtocol: \(maxProtocol), " +
            "client: <redacted>, role: \(role), scopes: \(scopes), caps: \(caps), " +
            "commands: \(commands), permissions: \(permissions), auth: \(authDescription), " +
            "locale: \(locale), device: \(deviceDescription))"
    }

    public var debugDescription: String { description }
}

public struct OpenClawResponseEnvelope: Decodable, Sendable, Equatable {
    public struct GatewayError: Decodable, Error, Sendable, Equatable {
        public let code: String
        public let message: String
        public let retryable: Bool?
        public let retryAfterMs: Int?
        public let details: JSONValue?
    }

    public let type: String
    public let id: String
    public let ok: Bool
    public let payload: JSONValue?
    public let error: GatewayError?
}

public struct OpenClawStateVersion: Decodable, Sendable, Equatable {
    public let presence: Int
    public let health: Int

    public init(presence: Int, health: Int) {
        self.presence = presence
        self.health = health
    }
}

public struct OpenClawEventEnvelope: Decodable, Sendable, Equatable {
    public let type: String
    public let event: String
    public let payload: JSONValue?
    public let seq: Int?
    public let stateVersion: OpenClawStateVersion?
}

/// Minimal recursive JSON value used only at the OpenClaw protocol edge.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsignedInteger(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(v): try c.encode(v)
        case let .integer(v): try c.encode(v)
        case let .unsignedInteger(v): try c.encode(v)
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
