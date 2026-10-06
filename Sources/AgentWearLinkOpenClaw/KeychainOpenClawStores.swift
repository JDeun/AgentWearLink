import Foundation
import Security

public enum OpenClawKeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

private struct OpenClawKeychain {
    let service: String

    func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OpenClawKeychainError.unexpectedStatus(status)
        }
        return data
    }

    func write(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let update = SecItemUpdate(
            base as CFDictionary,
            attributes as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw OpenClawKeychainError.unexpectedStatus(update)
        }

        var item = base
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        if add == errSecSuccess { return }
        if add == errSecDuplicateItem {
            let retry = SecItemUpdate(
                base as CFDictionary,
                attributes as CFDictionary
            )
            guard retry == errSecSuccess else {
                throw OpenClawKeychainError.unexpectedStatus(retry)
            }
            return
        }
        throw OpenClawKeychainError.unexpectedStatus(add)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenClawKeychainError.unexpectedStatus(status)
        }
    }
}

public actor KeychainOpenClawDeviceIdentityStore: OpenClawDeviceIdentityStore {
    private let keychain: OpenClawKeychain
    private let account = "device-identity-v1"

    public init(service: String = "dev.agentwearlink.openclaw") {
        self.keychain = OpenClawKeychain(service: service)
    }

    public func load() async throws -> OpenClawDeviceIdentity? {
        guard let data = try keychain.read(account: account) else { return nil }
        return try OpenClawDeviceIdentity(privateKeyRaw: data)
    }

    public func save(_ identity: OpenClawDeviceIdentity) async throws {
        try keychain.write(identity.privateKeyRaw, account: account)
    }
}

public actor KeychainOpenClawDeviceCredentialStore: OpenClawDeviceCredentialStore {
    private let keychain: OpenClawKeychain

    public init(service: String = "dev.agentwearlink.openclaw") {
        self.keychain = OpenClawKeychain(service: service)
    }

    private func account(deviceID: String, role: String) -> String {
        "device-token-v1|\(deviceID)|\(role)"
    }

    public func load(
        deviceID: String,
        role: String
    ) async throws -> OpenClawDeviceCredential? {
        guard let data = try keychain.read(
            account: account(deviceID: deviceID, role: role)
        ) else {
            return nil
        }
        return try JSONDecoder().decode(OpenClawDeviceCredential.self, from: data)
    }

    public func save(_ credential: OpenClawDeviceCredential) async throws {
        let data = try JSONEncoder().encode(credential)
        try keychain.write(
            data,
            account: account(
                deviceID: credential.deviceID,
                role: credential.role
            )
        )
    }

    public func remove(deviceID: String, role: String) async throws {
        try keychain.delete(account: account(deviceID: deviceID, role: role))
    }
}
