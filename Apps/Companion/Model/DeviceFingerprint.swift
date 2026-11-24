import Foundation

/// Human-comparable form of the OpenClaw device id (SHA-256 of the device
/// public key, hex). The Gateway's pending-device list shows the same id, so
/// the user can check that the request being approved is this iPhone.
public enum DeviceFingerprint {
    /// "A1B2-C3D4": the first eight hex digits, grouped.
    public static func short(_ deviceID: String) -> String {
        let hex = deviceID.lowercased().filter { $0.isHexDigit }
        guard hex.count >= 8 else { return hex.uppercased() }
        let prefix = hex.prefix(8).uppercased()
        return "\(prefix.prefix(4))-\(prefix.suffix(4))"
    }

    /// The full id in groups of four for the Settings screen.
    public static func grouped(_ deviceID: String) -> String {
        let hex = Array(deviceID.lowercased().filter { $0.isHexDigit })
        return stride(from: 0, to: hex.count, by: 4)
            .map { String(hex[$0..<min($0 + 4, hex.count)]) }
            .joined(separator: " ")
    }
}
