import Foundation

public struct AgentRequest: Sendable, Equatable, Codable {
    public let interactionID: InteractionID
    public let text: String

    public init(interactionID: InteractionID, text: String) {
        self.interactionID = interactionID
        self.text = text
    }
}

public enum AgentResponse: Sendable, Equatable {
    case textDelta(InteractionID, String)
    case completed(InteractionID)
    case failed(InteractionID, AWLError)

    public var interactionID: InteractionID {
        switch self {
        case let .textDelta(id, _), let .completed(id), let .failed(id, _):
            return id
        }
    }
}
