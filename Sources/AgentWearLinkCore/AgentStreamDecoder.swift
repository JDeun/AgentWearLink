import Foundation

public protocol AgentStreamDecoder: Sendable {
    func decode(
        event: ServerSentEvent,
        interactionID: InteractionID
    ) throws -> AgentResponse?
}

/// Simple decoder useful for gateways that stream plain text in SSE data
/// fields and use an explicit completion event.
///
/// Runtime-specific JSON formats should provide their own decoder.
public struct PlainTextSSEDecoder: AgentStreamDecoder {
    public let completionEventName: String

    public init(completionEventName: String = "done") {
        self.completionEventName = completionEventName
    }

    public func decode(
        event: ServerSentEvent,
        interactionID: InteractionID
    ) throws -> AgentResponse? {
        if event.event == completionEventName || event.data == "[DONE]" {
            return .completed(interactionID)
        }
        guard !event.data.isEmpty else { return nil }
        return .textDelta(interactionID, event.data)
    }
}
