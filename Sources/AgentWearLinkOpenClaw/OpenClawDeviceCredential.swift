import CryptoKit
import Foundation

public enum OpenClawCredentialNamespaceError: Error, Sendable, Equatable {
    case invalidStableIdentifier
}

/// Stable pre-auth partition for persisted Gateway device grants.
///
/// Endpoint-derived namespaces are intentionally conservative: different
/// aliases remain different namespaces unless the host explicitly supplies the
/// same stable identifier. This prevents a grant issued by one Gateway from
/// being presented to another by mistake.
public struct OpenClawGatewayCredentialNamespace:
    Sendable,
    Hashable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    private static let maximumStableIdentifierBytes = 256
    private let canonicalIdentifier: String

    public init(endpoint: OpenClawEndpoint) {
        self.canonicalIdentifier =
            "endpoint-v1|" + Self.canonicalEndpoint(endpoint.gatewayURL)
    }

    /// Creates an explicit namespace for multiple trusted aliases of the same
    /// Gateway. Callers must only reuse an identifier when they already know
    /// the aliases terminate at the same OpenClaw Gateway.
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

    public var description: String {
        "OpenClawGatewayCredentialNamespace(<redacted>)"
    }

    public var debugDescription: String { description }

    fileprivate var storageKeyDigest: String {
        let digest = SHA256.hash(data: Data(canonicalIdentifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalEndpoint(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url.absoluteString
        }

        switch components.scheme?.lowercased() {
        case "http", "ws":
            components.scheme = "ws"
        case "https", "wss":
            components.scheme = "wss"
        default:
            components.scheme = components.scheme?.lowercased()
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

/// Source-compatible namespace adapter for any existing credential store.
///
/// The wrapped store receives a namespaced storage device ID while callers see
/// the original OpenClaw device ID. Existing unscoped records are deliberately
/// not auto-migrated: assigning an old token to a newly configured endpoint
/// without authenticated server identity would risk cross-Gateway credential
/// confusion. A namespace upgrade therefore fails closed and re-pairs once.
public struct GatewayScopedOpenClawDeviceCredentialStore:
    OpenClawDeviceCredentialStore
{
    private let base: any OpenClawDeviceCredentialStore
    private let namespace: OpenClawGatewayCredentialNamespace

    public init(
        base: any OpenClawDeviceCredentialStore,
        namespace: OpenClawGatewayCredentialNamespace
    ) {
        self.base = base
        self.namespace = namespace
    }

    private func storageDeviceID(_ deviceID: String) -> String {
        "gateway-v2|\(namespace.storageKeyDigest)|\(deviceID)"
    }

    private func storageCredential(
        _ credential: OpenClawDeviceCredential
    ) -> OpenClawDeviceCredential {
        .init(
            deviceID: storageDeviceID(credential.deviceID),
            role: credential.role,
            requestedRole: credential.requestedRole,
            storageRoleOverride: credential.storageRoleOverride,
            scopes: credential.scopes,
            token: credential.token
        )
    }

    private func externalCredential(
        _ credential: OpenClawDeviceCredential,
        deviceID: String
    ) -> OpenClawDeviceCredential? {
        guard credential.deviceID == storageDeviceID(deviceID) else {
            return nil
        }
        return .init(
            deviceID: deviceID,
            role: credential.role,
            requestedRole: credential.requestedRole,
            storageRoleOverride: credential.storageRoleOverride,
            scopes: credential.scopes,
            token: credential.token
        )
    }

    public func load(
        deviceID: String,
        role: String
    ) async throws -> OpenClawDeviceCredential? {
        guard let stored = try await base.load(
            deviceID: storageDeviceID(deviceID),
            role: role
        ) else {
            return nil
        }
        return externalCredential(stored, deviceID: deviceID)
    }

    public func save(_ credential: OpenClawDeviceCredential) async throws {
        try await base.save(storageCredential(credential))
    }

    public func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        try await base.compareAndSave(
            storageCredential(credential),
            expected: expected.map(storageCredential)
        )
    }

    public func compareAndRemove(
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        guard expected.deviceID == deviceID else { return false }
        return try await base.compareAndRemove(
            deviceID: storageDeviceID(deviceID),
            role: role,
            expected: storageCredential(expected)
        )
    }

    public func remove(deviceID: String, role: String) async throws {
        try await base.remove(
            deviceID: storageDeviceID(deviceID),
            role: role
        )
    }
}


public struct OpenClawDeviceCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceID: String
    /// Role actually granted by the Gateway in hello-ok.
    public let role: String
    /// Role requested before authentication. New records keep this so a
    /// downgraded/different authenticated role is still discoverable on the
    /// next connect without broadening the requested role.
    public let requestedRole: String?
    /// Optional internal storage partition for protocol grants that must remain
    /// distinct even when they share the same requested/authenticated role.
    /// Existing records decode this as nil and keep their historical key.
    public let storageRoleOverride: String?
    public let scopes: [String]
    public let token: String

    /// Stable lookup key used before the Gateway has returned hello-ok.
    /// Legacy records did not encode requestedRole/storageRoleOverride, so
    /// their authenticated role remains the lookup key.
    public var storageRole: String {
        storageRoleOverride ?? requestedRole ?? role
    }

    public var description: String {
        "OpenClawDeviceCredential(deviceID: \\(deviceID), role: \\(role), scopes: \\(scopes), token: <redacted>)"
    }
    public var debugDescription: String { description }

    public init(
        deviceID: String,
        role: String,
        requestedRole: String? = nil,
        storageRoleOverride: String? = nil,
        scopes: [String],
        token: String
    ) {
        self.deviceID = deviceID
        self.role = role
        self.requestedRole = requestedRole
        self.storageRoleOverride = storageRoleOverride
        self.scopes = scopes
        self.token = token
    }
}

public protocol OpenClawDeviceCredentialStore: Sendable {
    func load(deviceID: String, role: String) async throws -> OpenClawDeviceCredential?
    func save(_ credential: OpenClawDeviceCredential) async throws

    /// Atomically persists `credential` only when the currently stored value
    /// still equals `expected`. A nil expected value means "insert only if
    /// absent". Returns false when another lifecycle owner has already changed
    /// the record.
    func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool

    /// Atomically removes the record only when it still equals `expected`.
    /// This prevents stale handshake cleanup from deleting a newer grant.
    func compareAndRemove(
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool

    func remove(deviceID: String, role: String) async throws
}

public extension OpenClawDeviceCredentialStore {
    /// Compatibility fallback for third-party stores. Built-in AWL stores
    /// override this with a single-store atomic operation.
    func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        let current = try await load(
            deviceID: credential.deviceID,
            role: credential.storageRole
        )
        guard current == expected else { return false }
        try await save(credential)
        return true
    }

    /// Compatibility fallback for third-party stores. Built-in AWL stores
    /// override this with a single-store atomic operation.
    func compareAndRemove(
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        let current = try await load(deviceID: deviceID, role: role)
        guard current == expected else { return false }
        try await remove(deviceID: deviceID, role: role)
        return true
    }
}

public actor InMemoryOpenClawDeviceCredentialStore: OpenClawDeviceCredentialStore {
    private var values: [String: OpenClawDeviceCredential] = [:]

    public init() {}

    private func key(_ deviceID: String, _ role: String) -> String {
        "\(deviceID)|\(role)"
    }

    public func load(
        deviceID: String,
        role: String
    ) async throws -> OpenClawDeviceCredential? {
        values[key(deviceID, role)]
    }

    public func save(_ credential: OpenClawDeviceCredential) async throws {
        values[key(credential.deviceID, credential.storageRole)] = credential
    }

    public func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        let storageKey = key(credential.deviceID, credential.storageRole)
        guard values[storageKey] == expected else { return false }
        values[storageKey] = credential
        return true
    }

    public func compareAndRemove(
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        let storageKey = key(deviceID, role)
        guard values[storageKey] == expected else { return false }
        values[storageKey] = nil
        return true
    }

    public func remove(deviceID: String, role: String) async throws {
        values[key(deviceID, role)] = nil
    }
}
