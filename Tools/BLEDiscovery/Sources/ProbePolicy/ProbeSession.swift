import Foundation

enum ServiceFilter {
    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
        if (value.utf8.count == 4 || value.utf8.count == 8) && hex {
            return value.uppercased()
        }
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString
    }
}

enum ProbeStatus: String {
    case idle, waitingForBluetooth, scanning, completed, userStopped
    case unauthorized, poweredOff, unsupported, resetting, initializationTimedOut
    case candidateLimit, unknownState

    var isActive: Bool { self == .waitingForBluetooth || self == .scanning }
}

struct ProbeObservation {
    var localName: String?
    var advertisement = false
    var serviceAdvertised = false
    var serviceDataPresent = false
    var systemConnectedSnapshot = false
    var connectable: Bool?
}

struct ProbeCandidate: Identifiable, Equatable {
    let id: Int
    var localLabel: String?
    var advertisement = false
    var serviceAdvertised = false
    var serviceDataPresent = false
    var systemConnectedSnapshot = false
    var connectable: Bool?

    mutating func merge(_ observation: ProbeObservation) {
        if let name = observation.localName, !name.isEmpty {
            // Transient, untrusted display hint; never part of the report.
            let bounded = String(name.prefix(40)).filter { character in
                character.unicodeScalars.allSatisfy { scalar in
                    !CharacterSet.controlCharacters.contains(scalar)
                        && !CharacterSet.illegalCharacters.contains(scalar)
                        && !CharacterSet.newlines.contains(scalar)
                }
            }
            if !bounded.isEmpty { localLabel = bounded }
        }
        advertisement = advertisement || observation.advertisement
        serviceAdvertised = serviceAdvertised || observation.serviceAdvertised
        serviceDataPresent = serviceDataPresent || observation.serviceDataPresent
        systemConnectedSnapshot = systemConnectedSnapshot || observation.systemConnectedSnapshot
        if let flag = observation.connectable { connectable = flag }
    }
}

enum RecordResult: Equatable { case accepted, ignored, capacityExceeded }

/// Main-queue-owned, in-memory policy. No peripheral identifier enters the report.
struct ProbeSession {
    static let durationSeconds = 15
    static let candidateLimit = 16

    private(set) var status = ProbeStatus.idle
    private(set) var token: UUID?
    private(set) var candidates: [ProbeCandidate] = []
    private var indexes: [UUID: Int] = [:]
    private(set) var confirmedID: Int?
    private(set) var didRequestScan = false

    mutating func begin(token: UUID) -> Bool {
        guard !status.isActive else { return false }
        self = ProbeSession()
        self.token = token
        status = .waitingForBluetooth
        return true
    }

    mutating func startScan(token: UUID) -> Bool {
        guard self.token == token, status == .waitingForBluetooth else { return false }
        status = .scanning
        return true
    }

    mutating func markScanRequested(token: UUID) -> Bool {
        guard self.token == token, status == .scanning, !didRequestScan else { return false }
        didRequestScan = true
        return true
    }

    mutating func record(token: UUID, peripheralID: UUID,
                         observation: ProbeObservation) -> RecordResult {
        guard self.token == token, status == .scanning,
              !observation.advertisement || didRequestScan else { return .ignored }
        if let index = indexes[peripheralID] {
            candidates[index].merge(observation)
            return .accepted
        }
        guard candidates.count < Self.candidateLimit else { return .capacityExceeded }
        let index = candidates.count
        var candidate = ProbeCandidate(id: index + 1)
        candidate.merge(observation)
        indexes[peripheralID] = index
        candidates.append(candidate)
        return .accepted
    }

    @discardableResult
    mutating func finish(token: UUID, status outcome: ProbeStatus) -> Bool {
        guard self.token == token, status.isActive, !outcome.isActive,
              outcome != .idle else { return false }
        guard outcome != .completed || (status == .scanning && didRequestScan) else { return false }
        self.token = nil
        status = outcome
        indexes.removeAll()
        // Only a full scan can be reviewed/confirmed. Abort discards all hints.
        if outcome != .completed { candidates.removeAll() }
        confirmedID = nil
        return true
    }

    mutating func clear() { self = ProbeSession() }

    @discardableResult
    mutating func confirm(id: Int, independentlyIdentified: Bool) -> Bool {
        guard status == .completed, independentlyIdentified,
              candidates.contains(where: { $0.id == id }) else { return false }
        confirmedID = id
        return true
    }

    mutating func revokeConfirmation() { confirmedID = nil }

    var report: String {
        let candidate = candidates.first { $0.id == confirmedID }
        func flag(_ value: Bool?) -> String {
            guard let value else { return "not-observed" }
            return value ? "yes" : "no"
        }
        // Deliberately excludes UUIDs (including service filter), names, RSSI,
        // bytes, timestamps, manufacturer data and other peripheral metadata.
        return [
            "status=\(status.rawValue)",
            "scan-requested=\(flag(didRequestScan))",
            "candidate-count=\(candidates.count)",
            "owner-confirmed=\(flag(candidate != nil))",
            "advertisement-callback=\(flag(candidate?.advertisement))",
            "requested-service-advertised=\(flag(candidate?.advertisement == true ? candidate?.serviceAdvertised : nil))",
            "requested-service-data-present=\(flag(candidate?.advertisement == true ? candidate?.serviceDataPresent : nil))",
            "system-connected-at-start=\(flag(candidate?.systemConnectedSnapshot))",
            "connectable-flag=\(flag(candidate?.connectable))",
            "local-connection=not-attempted",
            "gatt-characteristics=not-tested",
            "l2cap=not-tested",
            "companion-authorization=not-tested",
            "wake-and-power=not-tested"
        ].joined(separator: "\n")
    }
}
