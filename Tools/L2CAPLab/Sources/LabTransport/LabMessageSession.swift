import Foundation

public enum LabMessagePhase: String, Equatable {
    case sendingHello, awaitingHello, sendingAccept, awaitingAccept
    case ready, sendingRequest, awaitingResponse, sendingResponse, finished
}

public enum LabMessageOutcome: String, Equatable {
    case cancelled, disconnected, endOfStream, negotiationTimeout, requestTimeout, idleTimeout, sessionTimeout
    case clockRegression, invalidNegotiation, unsupportedVersion, unsupportedCapability
    case unexpectedMessage, invalidCorrelation, invalidPayload, sequenceExhausted, transportFailure
}

public enum LabRequestAdmission: Equatable {
    case accepted(UInt32), busy, notReady, unsupportedSize, staleGeneration, terminal
}

public enum LabRequestResolution: Equatable {
    case verified, failed(LabMessageOutcome)
}

/// Metadata only, never retained request/response payloads or a peer identifier.
public struct LabRequestCompletion: Equatable {
    public let correlation: UInt32
    public let fixtureBytes: Int
    public let elapsedMS: UInt64
    public let resolution: LabRequestResolution
}

private struct PendingLabRequest {
    let correlation: UInt32
    let size: LabSize
    let startedAt: UInt64
}

/// Independent lab-only message session over the real framed transport.
/// One serial owner drives pump/tick and owns the underlying connection.
/// No credentials, private protocol, arbitrary command execution or retries.
/// A fresh authorized physical channel must have a fresh session/generation.
public struct LabMessageSession {
    public static let phaseLimitMS: UInt64 = 10_000
    public static let totalLimitMS: UInt64 = 60_000

    public let generation: UUID
    public let role: LabRole
    public let maximumSize: LabSize
    private let startedAt: UInt64
    private var phaseStartedAt: UInt64
    private var lastNow: UInt64
    private var transport: LabFramedTransport
    private var pending: PendingLabRequest?
    private var completion: LabRequestCompletion?
    private var nextCorrelation: UInt32 = 2
    private var cleanupPending = false

    public private(set) var phase: LabMessagePhase
    public private(set) var outcome: LabMessageOutcome?
    public private(set) var agreement: LabMessageAgreement?
    public private(set) var frameFailure: LabFrameError?
    /// Initiator: verified response. Responder: local response write accepted,
    /// NOT remote delivery. Never treat responder count alone as success.
    public private(set) var completedRequests = 0

    public init(generation: UUID, role: LabRole, maximumSize: LabSize = .large, nowMS: UInt64) throws {
        self.generation = generation
        self.role = role
        self.maximumSize = maximumSize
        startedAt = nowMS
        phaseStartedAt = nowMS
        lastNow = nowMS
        transport = LabFramedTransport(generation: generation)
        phase = role == .initiator ? .sendingHello : .awaitingHello
        if role == .initiator {
            guard try transport.enqueue(kind: .request, correlation: LabMessageNegotiation.correlation,
                                        payload: LabMessageNegotiation.hello(maximumSize: maximumSize),
                                        generation: generation) != nil else { throw LabFrameError.ioFailure }
        }
    }

    public var bufferedBytes: Int { transport.bufferedBytes }
    public var hasCompletion: Bool { completion != nil }
    public var hasPendingRequest: Bool { pending != nil }

    private mutating func finish(_ result: LabMessageOutcome, at now: UInt64) {
        guard phase != .finished else { return }
        if role == .initiator, let pending {
            // Admission requires a vacant completion slot, so exactly one
            // terminal resolution is observable even on partial TX/cancel.
            completion = LabRequestCompletion(correlation: pending.correlation, fixtureBytes: pending.size.rawValue,
                                              elapsedMS: now - pending.startedAt, resolution: .failed(result))
        }
        pending = nil
        transport.retire(generation: generation)
        phase = .finished
        outcome = result
        cleanupPending = true
    }

    private mutating func admit(_ token: UUID, _ now: UInt64) -> Bool {
        guard token == generation, phase != .finished else { return false }
        guard now >= lastNow else {
            finish(.clockRegression, at: lastNow)
            return false
        }
        lastNow = now
        if now - startedAt >= Self.totalLimitMS {
            finish(.sessionTimeout, at: now)
            return false
        }
        if now - phaseStartedAt >= Self.phaseLimitMS {
            let reason: LabMessageOutcome
            switch phase {
            case .sendingHello, .awaitingHello, .sendingAccept, .awaitingAccept: reason = .negotiationTimeout
            case .ready: reason = .idleTimeout
            case .sendingRequest, .awaitingResponse, .sendingResponse: reason = .requestTimeout
            case .finished: return false
            }
            finish(reason, at: now)
            return false
        }
        return true
    }

    /// Call independently of stream readiness; progress/duplicates never
    /// extend the negotiation, idle or request deadline.
    public mutating func tick(generation token: UUID, nowMS: UInt64) {
        _ = admit(token, nowMS)
    }

    private mutating func enterReady(at now: UInt64) {
        phase = .ready
        phaseStartedAt = now
    }

    private mutating func failTransport(_ error: LabFrameError, at now: UInt64) {
        frameFailure = error
        finish(error == .sequenceExhausted ? .sequenceExhausted : .transportFailure, at: now)
    }

    private mutating func failNegotiation(_ error: LabNegotiationError, at now: UInt64) {
        switch error {
        case .malformed: finish(.invalidNegotiation, at: now)
        case .unsupportedVersion: finish(.unsupportedVersion, at: now)
        case .unsupportedCapability: finish(.unsupportedCapability, at: now)
        }
    }

    private static func fixture(_ size: LabSize) -> [UInt8] {
        (0..<size.rawValue).map(LabSession.fixtureByte(at:))
    }

    private static func matches(_ bytes: [UInt8], size: LabSize) -> Bool {
        bytes.count == size.rawValue && bytes.enumerated().allSatisfy {
            $0.element == LabSession.fixtureByte(at: $0.offset)
        }
    }

    /// No application request is admitted before negotiated ready. Rejected
    /// admission consumes neither correlation nor sequence, and queues no data.
    public mutating func request(size: LabSize, generation token: UUID, nowMS: UInt64) -> LabRequestAdmission {
        guard token == generation else { return .staleGeneration }
        guard admit(token, nowMS) else { return .terminal }
        guard role == .initiator else { return .notReady }
        if phase == .sendingRequest || phase == .awaitingResponse || completion != nil { return .busy }
        guard phase == .ready, let agreement else { return .notReady }
        guard size.rawValue <= agreement.maximumPayload else { return .unsupportedSize }
        guard nextCorrelation <= LabFrameCodec.maxSequence else {
            finish(.sequenceExhausted, at: nowMS)
            return .terminal
        }
        let correlation = nextCorrelation
        do {
            guard try transport.enqueue(kind: .request, correlation: correlation, payload: Self.fixture(size),
                                        generation: token) != nil else { return .busy }
        } catch let error as LabFrameError {
            failTransport(error, at: nowMS)
            return .terminal
        } catch {
            failTransport(.ioFailure, at: nowMS)
            return .terminal
        }
        nextCorrelation += 1
        pending = PendingLabRequest(correlation: correlation, size: size, startedAt: nowMS)
        phase = .sendingRequest
        phaseStartedAt = nowMS
        return .accepted(correlation)
    }

    /// Cancellation is deliberately connection-fatal; partially accepted bytes
    /// cannot be unsent. No wire cancel, retry or reuse of an uncertain request.
    @discardableResult
    public mutating func cancelRequest(correlation: UInt32, generation token: UUID, nowMS: UInt64) -> Bool {
        guard token == generation, role == .initiator, pending?.correlation == correlation else { return false }
        guard admit(token, nowMS) else { return false }
        finish(.cancelled, at: nowMS)
        return true
    }

    public mutating func cancel(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS) else { return }
        finish(.cancelled, at: nowMS)
    }

    public mutating func disconnect(generation token: UUID, nowMS: UInt64) {
        guard admit(token, nowMS) else { return }
        finish(.disconnected, at: nowMS)
    }

    /// Even after terminal teardown the owner may retrieve the sole resolution.
    public mutating func takeCompletion(generation token: UUID) -> LabRequestCompletion? {
        guard token == generation else { return nil }
        let result = completion
        completion = nil
        return result
    }

    /// The owner must close streams/retire its OS connection, not just this value.
    public mutating func takeCleanupRequest(generation token: UUID) -> Bool {
        guard token == generation, cleanupPending else { return false }
        cleanupPending = false
        return true
    }

    /// Exactly one bounded LabPort operation; no automatic loops or retries.
    /// A terminal/stale callback touches neither clock nor port. The caller
    /// uses phase/readiness and independently calls tick even when I/O stalls.
    @discardableResult
    public mutating func pump(generation token: UUID, nowMS: UInt64, port: LabPort) -> LabFramePump {
        guard admit(token, nowMS) else { return .idle }
        do {
            switch phase {
            case .sendingHello, .sendingAccept, .sendingRequest, .sendingResponse:
                let result = try transport.pumpWrite(generation: token, port: port)
                if !transport.hasPendingWrite {
                    switch phase {
                    case .sendingHello: phase = .awaitingAccept
                    case .sendingAccept: enterReady(at: nowMS)
                    case .sendingRequest: phase = .awaitingResponse
                    case .sendingResponse:
                        completedRequests += 1
                        pending = nil
                        enterReady(at: nowMS)
                    default: break
                    }
                }
                return result
            case .awaitingHello, .awaitingAccept, .ready, .awaitingResponse:
                let result = try transport.pumpRead(generation: token, port: port)
                if result == .end {
                    finish(.endOfStream, at: nowMS)
                    return result
                }
                // No inbound application messages are valid at an idle initiator.
                // Reject even the first partial bytes, rather than letting them
                // become the next request's response.
                if role == .initiator, phase == .ready, case .progress = result {
                    finish(.unexpectedMessage, at: nowMS)
                    return result
                }
                if let frame = try transport.take(generation: token) {
                    try receive(frame, nowMS: nowMS)
                }
                return result
            case .finished:
                return .idle
            }
        } catch let error as LabNegotiationError {
            failNegotiation(error, at: nowMS)
        } catch let error as LabFrameError {
            failTransport(error, at: nowMS)
        } catch {
            failTransport(.ioFailure, at: nowMS)
        }
        return .idle
    }

    private mutating func receive(_ frame: LabFrame, nowMS: UInt64) throws {
        switch phase {
        case .awaitingHello:
            guard role == .responder, frame.kind == .request else { finish(.unexpectedMessage, at: nowMS); return }
            guard frame.correlation == LabMessageNegotiation.correlation else {
                finish(.invalidCorrelation, at: nowMS); return
            }
            let selected = try LabMessageNegotiation.select(hello: frame.payload, maximumSize: maximumSize)
            guard try transport.enqueue(kind: .response, correlation: frame.correlation,
                                        payload: LabMessageNegotiation.acceptBytes(selected),
                                        generation: generation) != nil else { throw LabFrameError.ioFailure }
            agreement = selected
            phase = .sendingAccept
        case .awaitingAccept:
            guard role == .initiator, frame.kind == .response else { finish(.unexpectedMessage, at: nowMS); return }
            guard frame.correlation == LabMessageNegotiation.correlation else {
                finish(.invalidCorrelation, at: nowMS); return
            }
            agreement = try LabMessageNegotiation.accept(frame.payload, offeredMaximum: maximumSize)
            enterReady(at: nowMS)
        case .ready:
            guard role == .responder, frame.kind == .request, let agreement else {
                finish(.unexpectedMessage, at: nowMS); return
            }
            guard frame.correlation == nextCorrelation else {
                finish(.invalidCorrelation, at: nowMS); return
            }
            guard let size = LabSize(rawValue: frame.payload.count),
                  size.rawValue <= agreement.maximumPayload, Self.matches(frame.payload, size: size) else {
                finish(.invalidPayload, at: nowMS); return
            }
            // Regenerate known synthetic bytes, never reflect arbitrary data.
            guard try transport.enqueue(kind: .response, correlation: frame.correlation,
                                        payload: Self.fixture(size), generation: generation) != nil else {
                throw LabFrameError.ioFailure
            }
            nextCorrelation += 1
            pending = PendingLabRequest(correlation: frame.correlation, size: size, startedAt: nowMS)
            phase = .sendingResponse
            phaseStartedAt = nowMS
        case .awaitingResponse:
            guard role == .initiator, frame.kind == .response, let pending else {
                finish(.unexpectedMessage, at: nowMS); return
            }
            guard frame.correlation == pending.correlation else {
                finish(.invalidCorrelation, at: nowMS); return
            }
            guard Self.matches(frame.payload, size: pending.size) else {
                finish(.invalidPayload, at: nowMS); return
            }
            completion = LabRequestCompletion(correlation: pending.correlation, fixtureBytes: pending.size.rawValue,
                                              elapsedMS: nowMS - pending.startedAt, resolution: .verified)
            self.pending = nil
            completedRequests += 1
            enterReady(at: nowMS)
        default:
            finish(.unexpectedMessage, at: nowMS)
        }
    }

    /// Distinct research-only report; never substitute for raw physical report v1.
    public var report: String {
        [
            "message-session-report-version=1",
            "scope=synthetic-framed-session-only",
            "role=\(role.rawValue)",
            "phase=\(phase.rawValue)",
            "outcome=\(outcome?.rawValue ?? "pending")",
            "negotiated-version=\(agreement.map { String($0.version) } ?? "not-observed")",
            "negotiated-max-payload=\(agreement.map { String($0.maximumPayload) } ?? "not-observed")",
            "completed-requests=\(completedRequests)",
            "completion-basis=\(role == .initiator ? "verified-response" : "local-write-accepted")",
            "physical-evidence=not-tested",
            "meta-transport=not-tested",
            "wake-and-power=not-tested"
        ].joined(separator: "\n")
    }
}
