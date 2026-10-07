import Foundation
import Security

public enum OpenClawKeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidData
}

private struct OpenClawKeychain {
    private static let mutationLock = NSLock()

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
        try Self.withMutationLock {
            try writeUnlocked(data, account: account)
        }
    }

    private func writeUnlocked(_ data: Data, account: String) throws {
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

    func addIfAbsent(_ data: Data, account: String) throws {
        try Self.withMutationLock {
            let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw OpenClawKeychainError.unexpectedStatus(status)
            }
        }
    }

    func compareAndWrite(
        _ data: Data,
        account: String,
        matchesExpected: (Data?) throws -> Bool
    ) throws -> Bool {
        try Self.withMutationLock {
            let current = try read(account: account)
            guard try matchesExpected(current) else { return false }

            if current == nil {
                let item: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String:
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                ]
                let status = SecItemAdd(item as CFDictionary, nil)
                if status == errSecSuccess { return true }
                if status == errSecDuplicateItem { return false }
                throw OpenClawKeychainError.unexpectedStatus(status)
            }

            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let status = SecItemUpdate(
                base as CFDictionary,
                attributes as CFDictionary
            )
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound { return false }
            throw OpenClawKeychainError.unexpectedStatus(status)
        }
    }

    func compareAndDelete(
        account: String,
        matchesExpected: (Data?) throws -> Bool
    ) throws -> Bool {
        try Self.withMutationLock {
            let current = try read(account: account)
            guard current != nil, try matchesExpected(current) else {
                return false
            }

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess { return true }
            if status == errSecItemNotFound { return false }
            throw OpenClawKeychainError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        try Self.withMutationLock {
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

    private static func withMutationLock<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try operation()
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

    public func loadOrCreate(_ candidate: OpenClawDeviceIdentity) async throws -> OpenClawDeviceIdentity {
        if let existing = try await load() { return existing }

        do {
            try keychain.addIfAbsent(candidate.privateKeyRaw, account: account)
            return candidate
        } catch OpenClawKeychainError.unexpectedStatus(errSecDuplicateItem) {
            guard let winner = try await load() else {
                throw OpenClawKeychainError.invalidData
            }
            return winner
        }
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
                role: credential.storageRole
            )
        )
    }

    public func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        if let expected,
           expected.deviceID != credential.deviceID ||
           expected.storageRole != credential.storageRole {
            return false
        }

        let data = try JSONEncoder().encode(credential)
        return try keychain.compareAndWrite(
            data,
            account: account(
                deviceID: credential.deviceID,
                role: credential.storageRole
            )
        ) { currentData in
            let current: OpenClawDeviceCredential?
            if let currentData {
                current = try JSONDecoder().decode(
                    OpenClawDeviceCredential.self,
                    from: currentData
                )
            } else {
                current = nil
            }
            return current == expected
        }
    }

    public func compareAndRemove(
        deviceID: String,
        role: String,
        expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        guard expected.deviceID == deviceID,
              expected.storageRole == role else {
            return false
        }

        return try keychain.compareAndDelete(
            account: account(deviceID: deviceID, role: role)
        ) { currentData in
            guard let currentData else { return false }
            let current = try JSONDecoder().decode(
                OpenClawDeviceCredential.self,
                from: currentData
            )
            return current == expected
        }
    }

    public func remove(deviceID: String, role: String) async throws {
        try keychain.delete(account: account(deviceID: deviceID, role: role))
    }
}
