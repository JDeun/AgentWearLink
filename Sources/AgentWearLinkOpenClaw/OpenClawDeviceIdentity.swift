import CryptoKit
import Foundation

public struct OpenClawDeviceIdentity: Sendable, Equatable, Codable {
    public let privateKeyRaw: Data

    public init(privateKeyRaw: Data) throws {
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        self.privateKeyRaw = privateKeyRaw
    }

    public static func generate() -> Self {
        let key = Curve25519.Signing.PrivateKey()
        return try! Self(privateKeyRaw: key.rawRepresentation)
    }

    public var publicKeyRaw: Data {
        get throws {
            try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyRaw
            ).publicKey.rawRepresentation
        }
    }

    /// Stable device id derived from the public key fingerprint.
    public var deviceID: String {
        get throws {
            let digest = SHA256.hash(data: try publicKeyRaw)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    public func sign(_ payload: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyRaw
        ).signature(for: payload)
    }
}

public protocol OpenClawDeviceIdentityStore: Sendable {
    func load() async throws -> OpenClawDeviceIdentity?
    func save(_ identity: OpenClawDeviceIdentity) async throws
    func loadOrCreate(_ candidate: OpenClawDeviceIdentity) async throws -> OpenClawDeviceIdentity
}

public extension OpenClawDeviceIdentityStore {
    func loadOrCreate(_ candidate: OpenClawDeviceIdentity) async throws -> OpenClawDeviceIdentity {
        if let existing = try await load() { return existing }
        try await save(candidate)
        return try await load() ?? candidate
    }
}

public actor InMemoryOpenClawDeviceIdentityStore: OpenClawDeviceIdentityStore {
    private var identity: OpenClawDeviceIdentity?

    public init(identity: OpenClawDeviceIdentity? = nil) {
        self.identity = identity
    }

    public func load() async throws -> OpenClawDeviceIdentity? { identity }

    public func save(_ identity: OpenClawDeviceIdentity) async throws {
        self.identity = identity
    }

    public func loadOrCreate(_ candidate: OpenClawDeviceIdentity) async throws -> OpenClawDeviceIdentity {
        if let identity { return identity }
        identity = candidate
        return candidate
    }
}

public actor OpenClawDeviceIdentityManager {
    private let store: any OpenClawDeviceIdentityStore

    public init(store: any OpenClawDeviceIdentityStore) {
        self.store = store
    }

    public func loadOrCreate() async throws -> OpenClawDeviceIdentity {
        try await store.loadOrCreate(OpenClawDeviceIdentity.generate())
    }
}
