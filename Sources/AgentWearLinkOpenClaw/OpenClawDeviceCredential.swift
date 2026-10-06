import Foundation

public struct OpenClawDeviceCredential: Codable, Sendable, Equatable {
    public let deviceID: String
    public let role: String
    public let scopes: [String]
    public let token: String

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
    func load(deviceID: String, role: String) async throws -> OpenClawDeviceCredential?
    func save(_ credential: OpenClawDeviceCredential) async throws
    func remove(deviceID: String, role: String) async throws
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
        values[key(credential.deviceID, credential.role)] = credential
    }

    public func remove(deviceID: String, role: String) async throws {
        values[key(deviceID, role)] = nil
    }
}
