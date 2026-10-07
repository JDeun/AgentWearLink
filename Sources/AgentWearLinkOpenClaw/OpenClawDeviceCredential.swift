import CryptoKit
import Foundation

public enum OpenClawCredentialNamespaceError: Error, Sendable, Equatable {
    case invalidStableIdentifier
}

/// Stable pre-auth identity used only to partition persisted device grants.
///
/// Endpoint-derived namespaces are conservative: different endpoint aliases are
/// different namespaces unless the host explicitly gives them the same stable
/// identifier. This prevents AWL from guessing that two addresses are the same
/// Gateway and accidentally cross-presenting a device grant.
public struct OpenClawGatewayCredentialNamespace:
    Sendable,
    Hashable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    private static let maximumStableIdentifierBytes = 256
    private static let legacyIdentifier = "legacy-unscoped-v1"

    private let canonicalIdentifier: String

    public init(endpoint: OpenClawEndpoint) {
        self.canonicalIdentifier =
            "endpoint-v1|" + Self.canonicalEndpoint(endpoint.gatewayURL)
    }

    /// Use the same explicit identifier for trusted aliases that intentionally
    /// address one Gateway (for example Tailnet Serve and a direct Tailnet URL).
    public init(stableIdentifier: String) throws {
        let trimmed = stableIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumStableIdentifierBytes,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw OpenClawCredentialNamespaceError.invalidStableIdentifier
        }
        self.canonicalIdentifier = "named-v1|" + trimmed
    }

    private init(canonicalIdentifier: String) {
        self.canonicalIdentifier = canonicalIdentifier
    }

    public var description: String {
        "OpenClawGatewayCredentialNamespace(<redacted>)"
    }

    public var debugDescription: String { description }

    /// Keychain account metadata uses only this digest, never the endpoint or
    /// stable alias text itself.
    var storageKeyDigest: String {
        let digest = SHA256.hash(data: Data(canonicalIdentifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static let legacyUnscoped = OpenClawGatewayCredentialNamespace(
        canonicalIdentifier: legacyIdentifier
    )

    var isLegacyUnscoped: Bool {
        canonicalIdentifier == Self.legacyIdentifier
    }

    private static func canonicalEndpoint(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url.absoluteString
        }

        let rawScheme = components.scheme?.lowercased()
        switch rawScheme {
        case "http", "ws":
            components.scheme = "ws"
        case "https", "wss":
            components.scheme = "wss"
        default:
            components.scheme = rawScheme
        }

        components.host = components.host?.lowercased()

        if (components.scheme == "ws" && components.port == 80)
            || (components.scheme == "wss" && components.port == 443) {
            components.port = nil
        }

        if components.path.isEmpty {
            components.path = "/"
        }
        components.fragment = nil

        return components.string ?? url.absoluteString
    }
}

public struct OpenClawDeviceCredential:
    Codable,
    Sendable,
    Equatable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let deviceID: String
    public let role: String
    public let scopes: [String]
    public let token: String

    public var description: String {
        "OpenClawDeviceCredential(deviceID: \(deviceID), role: \(role), scopes: \(scopes), token: <redacted>)"
    }
    public var debugDescription: String { description }

    public init(
        deviceID: String,
        role: String,
        scopes: [String],
        token: String
    ) {
        self.deviceID = deviceID
        self.role = role
        self.scopes = scopes
        self.token = token
    }
}

public protocol OpenClawDeviceCredentialStore: Sendable {
    func load(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String
    ) async throws -> OpenClawDeviceCredential?

    func save(
        _ credential: OpenClawDeviceCredential,
        namespace: OpenClawGatewayCredentialNamespace
    ) async throws

    /// Atomically persists `credential` only when the currently stored value
    /// in the exact Gateway namespace still equals `expected`.
    func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        namespace: OpenClawGatewayCredentialNamespace,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool

    /// Atomically removes the record only from the exact Gateway namespace when
    /// it still equals `expected`.
    func compareAndRemove(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool

    func remove(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String
    ) async throws
}

public extension OpenClawDeviceCredentialStore {
    /// Default CAS fallback for third-party stores. Built-in AWL stores
    /// override this with a single-store atomic operation.
    func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        namespace: OpenClawGatewayCredentialNamespace,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        let current = try await load(
            namespace: namespace,
            deviceID: credential.deviceID,
            role: credential.role
        )
        guard current == expected else { return false }
        try await save(credential, namespace: namespace)
        return true
    }

    /// Default compare-and-remove fallback for third-party stores.
    func compareAndRemove(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        let current = try await load(
            namespace: namespace,
            deviceID: deviceID,
            role: role
        )
        guard current == expected else { return false }
        try await remove(
            namespace: namespace,
            deviceID: deviceID,
            role: role
        )
        return true
    }

    // Compatibility access to the pre-namespace v1 bucket. Production
    // OpenClawConnectAssembler never uses these overloads.
    func load(
        deviceID: String,
        role: String
    ) async throws -> OpenClawDeviceCredential? {
        try await load(
            namespace: .legacyUnscoped,
            deviceID: deviceID,
            role: role
        )
    }

    func save(_ credential: OpenClawDeviceCredential) async throws {
        try await save(credential, namespace: .legacyUnscoped)
    }

    func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        try await compareAndSave(
            credential,
            namespace: .legacyUnscoped,
            expected: expected
        )
    }

    func compareAndRemove(
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        try await compareAndRemove(
            namespace: .legacyUnscoped,
            deviceID: deviceID,
            role: role,
            expected: expected
        )
    }

    func remove(deviceID: String, role: String) async throws {
        try await remove(
            namespace: .legacyUnscoped,
            deviceID: deviceID,
            role: role
        )
    }
}

public actor InMemoryOpenClawDeviceCredentialStore:
    OpenClawDeviceCredentialStore
{
    private var values: [String: OpenClawDeviceCredential] = [:]

    public init() {}

    private func key(
        _ namespace: OpenClawGatewayCredentialNamespace,
        _ deviceID: String,
        _ role: String
    ) -> String {
        "\(namespace.storageKeyDigest)|\(deviceID)|\(role)"
    }

    private func retireLegacy(
        afterWriting namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String
    ) {
        guard !namespace.isLegacyUnscoped else { return }
        values[key(.legacyUnscoped, deviceID, role)] = nil
    }

    public func load(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String
    ) async throws -> OpenClawDeviceCredential? {
        values[key(namespace, deviceID, role)]
    }

    public func save(
        _ credential: OpenClawDeviceCredential,
        namespace: OpenClawGatewayCredentialNamespace
    ) async throws {
        values[key(namespace, credential.deviceID, credential.role)] = credential
        retireLegacy(
            afterWriting: namespace,
            deviceID: credential.deviceID,
            role: credential.role
        )
    }

    public func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        namespace: OpenClawGatewayCredentialNamespace,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        let storageKey = key(namespace, credential.deviceID, credential.role)
        guard values[storageKey] == expected else { return false }
        values[storageKey] = credential
        retireLegacy(
            afterWriting: namespace,
            deviceID: credential.deviceID,
            role: credential.role
        )
        return true
    }

    public func compareAndRemove(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        let storageKey = key(namespace, deviceID, role)
        guard values[storageKey] == expected else { return false }
        values[storageKey] = nil
        return true
    }

    public func remove(
        namespace: OpenClawGatewayCredentialNamespace,
        deviceID: String,
        role: String
    ) async throws {
        values[key(namespace, deviceID, role)] = nil
    }
}
