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

/// Owns only the SDK transcription subscription. Attachment/start/stop remain
/// separate slices so transcript policy cannot accidentally own session lifecycle.
public final class MetaDATSpeechTranscriptStream: @unchecked Sendable {
    public init() {}

    public func stream(from speech: Speech) -> AsyncStream<MetaDATTranscript> {
        let tokens = ListenerTokenBag()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            speech.transcriptionPublisher.listen { result in
                continuation.yield(
                    MetaDATTranscript(
                        text: result.text,
                        isFinal: result.isFinal,
                        confidence: result.confidence >= 0 ? Double(result.confidence) : nil
                    )
                )
            }.store(in: tokens)
            continuation.onTermination = { [tokens] _ in
                Task { await tokens.cancelAll() }
            }
        }
    }
}
