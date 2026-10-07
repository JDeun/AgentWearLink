import Foundation

public struct OpenClawHelloOK: Decodable, Sendable, Equatable {
    public struct Server: Decodable, Sendable, Equatable {
        public let version: String
        public let connId: String
    }

    public struct Features: Decodable, Sendable, Equatable {
        public let methods: [String]
        public let events: [String]
    }

    public struct Auth: Decodable, Sendable, Equatable {
        public let role: String
        public let scopes: [String]
        public let deviceToken: String?
    }

    public struct Snapshot: Decodable, Sendable, Equatable {
        /// Presence and health are authoritative control-plane snapshots. AWL
        /// preserves their current wire shape without projecting vendor-owned
        /// subfields into Core.
        public let presence: [JSONValue]
        public let health: JSONValue
        public let stateVersion: OpenClawStateVersion
        public let uptimeMs: Int64
    }

    public struct Policy: Decodable, Sendable, Equatable {
        public struct Attachments: Decodable, Sendable, Equatable {
            public let maxBytes: Int
            public let maxImageBytes: Int
        }

        public let maxPayload: Int
        public let maxBufferedBytes: Int
        public let tickIntervalMs: Int
        public let attachments: Attachments?
    }

    public let type: String
    public let protocolVersion: Int
    public let server: Server
    public let features: Features
    /// Current OpenClaw always sends this snapshot. It remains optional at the
    /// decoder edge so older recorded fixtures can still be inspected safely.
    public let snapshot: Snapshot?
    public let auth: Auth
    public let policy: Policy

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case server
        case features
        case snapshot
        case auth
        case policy
    }
}

public struct OpenClawConnectChallenge: Decodable, Sendable, Equatable {
    public let nonce: String
    public let ts: Int64
}
