import Foundation

public struct OpenClawDeviceCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceID: String
    /// Role actually granted by the Gateway in hello-ok.
    public let role: String
    /// Role requested before authentication. New records keep this so a
    /// downgraded/different authenticated role is still discoverable on the
    /// next connect without broadening the requested role.
    public let requestedRole: String?
    public let scopes: [String]
    public let token: String

    /// Stable lookup key used before the Gateway has returned hello-ok.
    /// Legacy records did not encode requestedRole, so their authenticated
    /// role remains the lookup key.
    public var storageRole: String { requestedRole ?? role }

    public var description: String {
        "OpenClawDeviceCredential(deviceID: \\(deviceID), role: \\(role), scopes: \\(scopes), token: <redacted>)"
    }
    public var debugDescription: String { description }

    public init(
        deviceID: String,
        role: String,
        requestedRole: String? = nil,
        scopes: [String],
        token: String
    ) {
        self.deviceID = deviceID
        self.role = role
        self.requestedRole = requestedRole
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
