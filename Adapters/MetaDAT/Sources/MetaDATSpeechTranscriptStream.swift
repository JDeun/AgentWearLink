import Foundation
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

/// Owns only the SDK transcription subscription. Attachment/start/stop remain
/// separate slices so transcript policy cannot accidentally own session lifecycle.
public final class MetaDATSpeechTranscriptStream: @unchecked Sendable {
    private var token: (any AnyListenerToken)?
    private let lock = NSLock()

    public init() {}

    public func stream(from speech: Speech) -> AsyncStream<MetaDATTranscript> {
        AsyncStream { continuation in
            let listener = speech.transcriptionPublisher.listen { result in
                continuation.yield(
                    MetaDATTranscript(
                        text: result.text,
                        isFinal: result.isFinal,
                        confidence: result.confidence >= 0 ? result.confidence : nil
                    )
                )
            }
            lock.withLock { token = listener }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                let token = self.lock.withLock { () -> (any AnyListenerToken)? in
                    defer { self.token = nil }
                    return self.token
                }
                if let token { Task { await token.cancel() } }
            }
        }
    }
}
