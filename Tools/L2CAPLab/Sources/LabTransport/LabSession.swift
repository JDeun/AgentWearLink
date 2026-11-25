import Foundation

public enum LabRole: String, Equatable { case initiator, responder }
public enum LabSize: Int, CaseIterable {
    case small = 64, medium = 1024, large = 4096
}
public enum LabPhase: String, Equatable {
    case awaitingLink, awaitingChannel, transferring, finished
}
public enum LabOutcome: String, Equatable {
    case success, cancelled, disconnected, linkTimeout, channelTimeout, transferTimeout
    case clockRegression, ioError, invalidCount, unexpectedPayload, prematureEOF
}
public enum LabRead: Equatable {
    case wouldBlock, bytes([UInt8]), end
}

/// One synchronous, bounded operation per pump. The adapter must honor readiness
/// and never block waiting for radio or stream progress. A zero write is backpressure.
public protocol LabPort {
    func write(_ bytes: [UInt8]) throws -> Int
    func read(maxBytes: Int) throws -> LabRead
}

/// Single-owner/serial-executor policy; no radio, credentials, identifiers,
/// arbitrary input payload or device discovery. Fresh generation per explicit run.
public struct LabSession {
    public static let chunkLimit = 256
    public static let phaseLimitMS: UInt64 = 10_000
    public static let totalLimitMS: UInt64 = 30_000

    public let generation: UUID
    public let role: LabRole
    public let size: LabSize
    private let startedAt: UInt64
    private var phaseStartedAt: UInt64
    private var lastNow: UInt64
    private var cleanupPending = false
    public private(set) var phase: LabPhase = .awaitingLink
    public private(set) var outcome: LabOutcome?
    public private(set) var sent = 0
    public private(set) var received = 0
    public private(set) var linkElapsedMS: UInt64?
    public private(set) var channelElapsedMS: UInt64?
    public private(set) var transferElapsedMS: UInt64?
    public private(set) var totalElapsedMS: UInt64?

    public init(generation: UUID, role: LabRole, size: LabSize, nowMS: UInt64) {
        self.generation = generation
        self.role = role
        self.size = size
        startedAt = nowMS
        phaseStartedAt = nowMS
        lastNow = nowMS
    }

    /// Deterministic synthetic fixture; not a security challenge or peer identity.
    public static func fixtureByte(at offset: Int) -> UInt8 {
        // Mix the block index too: identical 256-byte chunks would hide reorder/replay.
        UInt8(truncatingIfNeeded: ((offset &* 31) &+ 17) ^ ((offset >> 8) &* 73))
    }

    private mutating func finish(_ result: LabOutcome, at now: UInt64) {
        guard phase != .finished else { return }
        if phase == .transferring { transferElapsedMS = now - phaseStartedAt }
        totalElapsedMS = now - startedAt
        outcome = result
        phase = .finished
        cleanupPending = true
    }

    /// Reject stale/terminal callbacks before reading the clock or touching I/O.
    private mutating func admit(_ token: UUID, _ now: UInt64) -> Bool {
        guard token == generation, phase != .finished else { return false }
        guard now >= lastNow else {
            finish(.clockRegression, at: lastNow)
            return false
        }
        lastNow = now
        if now - phaseStartedAt >= Self.phaseLimitMS || now - startedAt >= Self.totalLimitMS {
            let reason: LabOutcome
            switch phase {
            case .awaitingLink: reason = .linkTimeout
            case .awaitingChannel: reason = .channelTimeout
            case .transferring: reason = .transferTimeout
            case .finished: return false
            }
            finish(reason, at: now)
            return false
        }
        return true
    }

    /// Call from an independent timer even when no stream readiness arrives.
    public mutating func tick(generation token: UUID, nowMS: UInt64) {
        _ = admit(token, nowMS)
    }

    public mutating func linkConnected(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS), phase == .awaitingLink else { return }
        linkElapsedMS = nowMS - phaseStartedAt
        phaseStartedAt = nowMS
        phase = .awaitingChannel
    }

    public mutating func channelOpened(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS), phase == .awaitingChannel else { return }
        channelElapsedMS = nowMS - phaseStartedAt
        phaseStartedAt = nowMS
        phase = .transferring
    }

    public mutating func cancel(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS) else { return }
        finish(.cancelled, at: nowMS)
    }

    public mutating func disconnect(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS) else { return }
        finish(.disconnected, at: nowMS)
    }

    public mutating func failIO(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS) else { return }
        finish(.ioError, at: nowMS)
    }

    /// One cleanup obligation on every terminal path (including before link/open).
    /// The platform owner must close/unschedule streams, retire delegates and cancel
    /// the local connection or fixture service; never auto-retry.
    public mutating func takeCleanupRequest(generation token: UUID) -> Bool {
        guard token == generation, cleanupPending else { return false }
        cleanupPending = false
        return true
    }

    /// Exactly one bounded write or read, no retry loop or buffering of peer data.
    /// Responder verifies the complete fixture before emitting its own synthetic bytes.
    /// Initiator succeeds only after the full fixture has been written and verified back.
    public mutating func pump(generation token: UUID, nowMS: UInt64, port: LabPort) {
        guard admit(token, nowMS), phase == .transferring else { return }
        let count = size.rawValue
        let shouldWrite = sent < count && (role == .initiator || received == count)
        do {
            if shouldWrite {
                let offered = min(Self.chunkLimit, count - sent)
                let bytes = (sent..<(sent + offered)).map(Self.fixtureByte(at:))
                let written = try port.write(bytes)
                guard written >= 0, written <= offered else {
                    finish(.invalidCount, at: nowMS)
                    return
                }
                sent += written
            } else if received < count {
                // Request at most a chunk. Check for overrun in this read;
                // bytes arriving after terminal cleanup are not examined.
                switch try port.read(maxBytes: Self.chunkLimit) {
                case .wouldBlock: break
                case .end:
                    finish(.prematureEOF, at: nowMS)
                    return
                case .bytes(let bytes):
                    guard !bytes.isEmpty, bytes.count <= Self.chunkLimit,
                          bytes.count <= count - received else {
                        finish(.invalidCount, at: nowMS)
                        return
                    }
                    for (index, byte) in bytes.enumerated() {
                        guard byte == Self.fixtureByte(at: received + index) else {
                            finish(.unexpectedPayload, at: nowMS)
                            return
                        }
                    }
                    received += bytes.count
                }
            }
        } catch {
            finish(.ioError, at: nowMS)
            return
        }
        if sent == count && received == count {
            finish(.success, at: nowMS)
        }
    }

    /// Categorical outcome and stage timings; no token or payload export.
    public var report: String {
        func timing(_ value: UInt64?) -> String { value.map { String($0) } ?? "not-observed" }
        return [
            "report-version=1",
            "scope=synthetic-lab-only",
            "role=\(role.rawValue)",
            "phase=\(phase.rawValue)",
            "outcome=\(outcome?.rawValue ?? "pending")",
            "fixture-bytes=\(size.rawValue)",
            "sent-bytes=\(sent)",
            "verified-received-bytes=\(received)",
            "link-elapsed-ms=\(timing(linkElapsedMS))",
            "channel-elapsed-ms=\(timing(channelElapsedMS))",
            "transfer-elapsed-ms=\(timing(transferElapsedMS))",
            "total-elapsed-ms=\(timing(totalElapsedMS))",
            "meta-transport=not-tested",
            "wake-and-power=not-tested"
        ].joined(separator: "\n")
    }
}
