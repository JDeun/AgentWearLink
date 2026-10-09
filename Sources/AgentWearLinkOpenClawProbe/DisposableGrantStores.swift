import AgentWearLinkOpenClaw
import Foundation

/// Test-only storage shared by two sequential Swift probe processes.
/// Its parent is a Python-created, 0700 disposable directory that is removed
/// at the end of the real Gateway CI job. This is NEVER a production store.
enum DisposableGrantStoreError: Error {
    case invalidDirectory
    case invalidPermissions
}

private enum DisposableProbeDisk {
    static func verifyDirectory(_ directory: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw DisposableGrantStoreError.invalidDirectory
        }
    }

    static func read(_ file: URL, directory: URL) throws -> Data? {
        try verifyDirectory(directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw DisposableGrantStoreError.invalidPermissions
        }
        return try Data(contentsOf: file)
    }

    static func write(_ data: Data, file: URL, directory: URL) throws {
        try verifyDirectory(directory)
        // Atomic replacement with a private parent directory. A temporary
        // file is not accessible to other users, and both the resulting file
        // and its replacement are explicitly verified before reuse.
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: file.path
        )
        _ = try read(file, directory: directory)
    }

    static func remove(_ file: URL, directory: URL) throws {
        _ = try read(file, directory: directory)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

actor DisposableProbeIdentityStore: OpenClawDeviceIdentityStore {
    private let directory: URL
    private var path: URL { directory.appendingPathComponent("identity.raw") }

    init(directory: URL) { self.directory = directory }

    func load() async throws -> OpenClawDeviceIdentity? {
        guard let bytes = try DisposableProbeDisk.read(path, directory: directory) else {
            return nil
        }
        return try OpenClawDeviceIdentity(privateKeyRaw: bytes)
    }

    func save(_ identity: OpenClawDeviceIdentity) async throws {
        try DisposableProbeDisk.write(identity.privateKeyRaw, file: path, directory: directory)
    }

    func loadOrCreate(_ candidate: OpenClawDeviceIdentity) async throws -> OpenClawDeviceIdentity {
        if let identity = try await load() { return identity }
        try await save(candidate)
        return candidate
    }
}

actor DisposableProbeCredentialStore: OpenClawDeviceCredentialStore {
    private let directory: URL
    private var path: URL { directory.appendingPathComponent("grant.json") }

    init(directory: URL) { self.directory = directory }

    func load(deviceID: String, role: String) async throws -> OpenClawDeviceCredential? {
        guard let data = try DisposableProbeDisk.read(path, directory: directory) else {
            return nil
        }
        let record = try JSONDecoder().decode(OpenClawDeviceCredential.self, from: data)
        return record.deviceID == deviceID && record.storageRole == role ? record : nil
    }

    func save(_ credential: OpenClawDeviceCredential) async throws {
        try DisposableProbeDisk.write(
            try JSONEncoder().encode(credential), file: path, directory: directory
        )
    }

    func compareAndSave(
        _ credential: OpenClawDeviceCredential,
        expected: OpenClawDeviceCredential?
    ) async throws -> Bool {
        let current = try await load(
            deviceID: credential.deviceID, role: credential.storageRole
        )
        guard current == expected else { return false }
        try await save(credential)
        return true
    }

    func compareAndRemove(
        deviceID: String, role: String, expected: OpenClawDeviceCredential
    ) async throws -> Bool {
        guard let current = try await load(deviceID: deviceID, role: role),
              current == expected else { return false }
        try DisposableProbeDisk.remove(path, directory: directory)
        return true
    }

    func remove(deviceID: String, role: String) async throws {
        guard try await load(deviceID: deviceID, role: role) != nil else { return }
        try DisposableProbeDisk.remove(path, directory: directory)
    }
}
