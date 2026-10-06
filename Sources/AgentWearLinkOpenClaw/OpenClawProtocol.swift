import Foundation

public enum OpenClawProtocol {
    public static let currentVersion = 4
    public static let defaultGatewayPort = 18_789
    public static let preAuthMaximumBytes = 64 * 1024
}

public struct OpenClawRequestFrame<Params: Encodable & Sendable>: Encodable, Sendable {
    public let type = "req"
    public let id: String
    public let method: String
    public let params: Params

    public init(id: String, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct OpenClawConnectParams: Encodable, Sendable {
    public struct Client: Encodable, Sendable {
        public let id: String
        public let version: String
        public let platform: String
        public let mode: String

        public init(
            id: String = "agentwearlink",
            version: String,
            platform: String = "ios",
            mode: String = "operator"
        ) {
            self.id = id
            self.version = version
            self.platform = platform
            self.mode = mode
        }
    }

    public struct Auth: Encodable, Sendable {
        public let token: String?
        public let password: String?
        public let bootstrapToken: String?

        public init(
            token: String? = nil,
            password: String? = nil,
            bootstrapToken: String? = nil
        ) {
            self.token = token
            self.password = password
            self.bootstrapToken = bootstrapToken
        }
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
        scopes: [String] = ["operator.read", "operator.write"],
        auth: Auth? = nil,
        locale: String = "en-US",
        device: OpenClawDeviceProof? = nil
    ) {
        self.minProtocol = OpenClawProtocol.currentVersion
        self.maxProtocol = OpenClawProtocol.currentVersion
        self.client = Client(version: version)
        self.role = "operator"
        self.scopes = scopes
        self.caps = []
        self.commands = []
        self.permissions = [:]
        self.auth = auth
        self.locale = locale
        self.device = device
    }
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

public struct OpenClawEventEnvelope: Decodable, Sendable, Equatable {
    public let type: String
    public let event: String
    public let payload: JSONValue?
    public let seq: Int?
    public let stateVersion: Int?
}

/// Minimal recursive JSON value used only at the OpenClaw protocol edge.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
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
        case let .number(v): try c.encode(v)
        case let .bool(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
