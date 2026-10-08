import Foundation

/// Event names and identifiers only. There is deliberately no arbitrary text,
/// error description, URL, token, transcript, payload, or private media field.
public enum AWLDiagnosticKind: String, Sendable, Equatable, Codable {
    case runtimeActivated
    case runtimeRetired
    case requestAccepted
    case requestDuplicate
    case requestOversize
    case requestCapacity
    case responseCompleted
    case responseFailed
    case cancellationRequested
    case cancellationUncertain
    case transportConnected
    case transportReconnecting
    case transportRetry
    case transportRecovered
    case transportStopped
    case transportFailed
    case metaConnectStarted
    case metaSessionReady
    case metaMediaRetired
    case metaBackgroundRetired
    case metaSnapshotRequested
    case metaSnapshotCompleted
    case metaSnapshotFailed
    case metaTranscriptAccepted
}

public struct AWLDiagnosticEvent: Sendable, Equatable {
    public let kind: AWLDiagnosticKind
    public let interactionID: InteractionID?
    public let generation: UInt64?
    public let attempt: Int?

    public init(
        kind: AWLDiagnosticKind,
        interactionID: InteractionID? = nil,
        generation: UInt64? = nil,
        attempt: Int? = nil
    ) {
        self.kind = kind
        self.interactionID = interactionID
        self.generation = generation
        self.attempt = attempt
    }
}

/// Opt-in, in-memory and bounded diagnostic recorder for local validation.
/// Recording performs no I/O, invokes no client callback and never suspends
/// an interaction. A host may explicitly read/drain and export sanitized data.
public final class AWLDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var events: [AWLDiagnosticEvent] = []
    private var dropped = 0

    public init(capacity: Int = 256) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func record(_ event: AWLDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        if events.count == capacity {
            events.removeFirst()
            dropped += 1
        }
        events.append(event)
    }

    public func snapshot() -> [AWLDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func drain() -> [AWLDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        let recorded = events
        events.removeAll(keepingCapacity: true)
        return recorded
    }

    public var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}
