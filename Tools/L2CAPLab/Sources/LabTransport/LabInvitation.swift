import Foundation

/// One-run synthetic lab invitation. Namespace and descriptor are scope guards,
/// not credentials or cryptographic identity. Never put invitation in reports.
public struct LabInvitation: Equatable {
    public static let servicePrefix = "A71BCAFE-"
    public static let markerUUID = "A71BCAFD-3713-4D25-AD0B-F3AF0A74C899"
    public let serviceID: UUID
    public let psm: UInt16
    public let size: LabSize

    public static func newServiceID() -> UUID {
        let value = UUID().uuidString
        return UUID(uuidString: "A71BCAFE" + String(value.dropFirst(8)))!
    }

    public init?(serviceID: UUID, psm: UInt16, size: LabSize) {
        guard serviceID.uuidString.hasPrefix(Self.servicePrefix),
              (0x0080...0x00FF).contains(psm) else { return nil }
        self.serviceID = serviceID
        self.psm = psm
        self.size = size
    }

    public init?(_ localText: String) {
        guard localText.utf8.count <= 100 else { return nil }
        let pieces = localText.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0] == "AWL-LAB1",
              let serviceID = UUID(uuidString: String(pieces[1])),
              let psm = UInt16(pieces[2]),
              let count = Int(pieces[3]), let size = LabSize(rawValue: count)
        else { return nil }
        self.init(serviceID: serviceID, psm: psm, size: size)
    }

    public var localText: String {
        "AWL-LAB1|\(serviceID.uuidString)|\(psm)|\(size.rawValue)"
    }

    /// Synthetic static characteristic value. No device identity or secrets.
    public var marker: Data {
        Data([0x41, 0x57, 0x4C, 0x01,
              UInt8(truncatingIfNeeded: psm >> 8), UInt8(truncatingIfNeeded: psm),
              UInt8(truncatingIfNeeded: size.rawValue >> 8), UInt8(truncatingIfNeeded: size.rawValue)])
    }

    public func matchesMarker(_ data: Data?) -> Bool { data == marker }
}
