import Foundation
import MWDATCore
import MWDATSpeech

public struct MetaDATTranscript: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?

    public init(text: String, isFinal: Bool, confidence: Double?) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

/// Overflow is local to Speech. It must not be reported as a nil-ID global
/// device overflow, which would unnecessarily retire camera and Voice Invocation.
public enum MetaDATSpeechDeliveryError: Error, Sendable, Equatable {
    case finalTranscriptOverflow
}

/// Single-consumer, bounded queue for a single Speech listener. Partials are
/// expendable telemetry; admitted final transcripts retain their FIFO order.
/// Losing a final invalidates pending delivery and produces an explicit failure.
public final class MetaDATSpeechTranscriptDelivery: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case transcript(MetaDATTranscript)
        case failed(MetaDATSpeechDeliveryError)
    }

    private let lock = NSLock()
    private let limit: Int
    private let maximumTranscriptBytes: Int
    private var pending: [MetaDATTranscript] = []
    private var waiter: CheckedContinuation<Event?, Never>?
    private var listener: (any AnyListenerToken)?
    private var closed = false
    private var failurePending = false
    private var overflowed = false

    init(limit: Int = 8, maximumTranscriptBytes: Int = 16 * 1024) {
        precondition(limit > 0 && maximumTranscriptBytes > 0)
        self.limit = limit
        self.maximumTranscriptBytes = maximumTranscriptBytes
    }

    deinit {
        if let listener {
            Task { await listener.cancel() }
        }
    }

    func attach(_ token: any AnyListenerToken) {
        let cancelImmediately = lock.withLock {
            guard !closed else { return true }
            listener = token
            return false
        }
        if cancelImmediately { Task { await token.cancel() } }
    }

    func offer(_ transcript: MetaDATTranscript) {
        lock.lock()
        guard !closed else { lock.unlock(); return }

        let oversized = transcript.text.utf8.count > maximumTranscriptBytes
        if !oversized, let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: .transcript(transcript))
            return
        }

        if !oversized, pending.count < limit {
            pending.append(transcript)
            lock.unlock()
            return
        }

        if !oversized, let partial = pending.firstIndex(where: { !$0.isFinal }) {
            // Remove only an old partial. A newer partial cannot evict a final.
            pending.remove(at: partial)
            pending.append(transcript)
            lock.unlock()
            return
        }

        guard transcript.isFinal else { lock.unlock(); return }

        // All slots hold finals (or this final exceeds the byte bound).
        // Stop further submissions; a partial must never mask this failure.
        overflowed = true
        closed = true
        pending.removeAll(keepingCapacity: false)
        let waiting = waiter
        waiter = nil
        failurePending = waiting == nil
        let token = listener
        listener = nil
        lock.unlock()
        waiting?.resume(returning: .failed(.finalTranscriptOverflow))
        if let token { Task { await token.cancel() } }
    }

    /// Commit an already normalized final only while its delivery is healthy.
    /// This synchronous boundary serializes event publication with overflow.
    @discardableResult
    func commitIfHealthy(_ commit: () -> Void) -> Bool {
        lock.withLock {
            guard !closed, !overflowed else { return false }
            commit()
            return true
        }
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.cancel() })
    }

    private func next() async -> Event? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled || waiter != nil {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else if failurePending {
                    failurePending = false
                    lock.unlock()
                    continuation.resume(returning: .failed(.finalTranscriptOverflow))
                } else if !pending.isEmpty {
                    let value = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: .transcript(value))
                } else if closed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        closed = true
        failurePending = false
        pending.removeAll(keepingCapacity: false)
        let waiting = waiter
        waiter = nil
        let token = listener
        listener = nil
        lock.unlock()
        waiting?.resume(returning: nil)
        if let token { Task { await token.cancel() } }
    }
}

/// Owns only the SDK transcription subscription. Attachment/start/stop remain
/// separate so transcript policy cannot accidentally own session lifecycle.
public final class MetaDATSpeechTranscriptStream: @unchecked Sendable {
    public init() {}

    public func subscribe(from speech: Speech) -> MetaDATSpeechTranscriptDelivery {
        let delivery = MetaDATSpeechTranscriptDelivery()
        let token = speech.transcriptionPublisher.listen { [weak delivery] result in
            delivery?.offer(MetaDATTranscript(
                text: result.text,
                isFinal: result.isFinal,
                confidence: result.confidence >= 0 ? Double(result.confidence) : nil
            ))
        }
        delivery.attach(token)
        return delivery
    }
}
