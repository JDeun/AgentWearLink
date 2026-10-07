import Foundation

public struct AgentRequest: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultMaximumTextBytes = 262_144

    public let interactionID: InteractionID
    public let text: String

    public init(interactionID: InteractionID, text: String) {
        self.interactionID = interactionID
        self.text = text
    }

    public var textUTF8ByteCount: Int {
        text.utf8.count
    }

    public func validateMaximumTextBytes(_ maximumBytes: Int) throws {
        precondition(maximumBytes > 0)
        let actual = textUTF8ByteCount
        guard actual <= maximumBytes else {
            throw AgentRequestValidationError.payloadTooLarge(
                actual: actual,
                maximum: maximumBytes
            )
        }
    }

    public var description: String {
        "AgentRequest(interactionID: \(interactionID.rawValue.uuidString), textBytes: \(text.utf8.count))"
    }

    public var debugDescription: String { description }
}

public enum AgentRequestValidationError: Error, Sendable, Equatable {
    case payloadTooLarge(actual: Int, maximum: Int)
}

public enum AgentResponse: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case textDelta(InteractionID, String)
    case completed(InteractionID)
    case failed(InteractionID, AWLError)

    public var interactionID: InteractionID {
        switch self {
        case let .textDelta(id, _), let .completed(id), let .failed(id, _):
            return id
        }
    }

    public var description: String {
        switch self {
        case let .textDelta(id, text):
            return "AgentResponse.textDelta(interactionID: \(id.rawValue.uuidString), textBytes: \(text.utf8.count))"
        case let .completed(id):
            return "AgentResponse.completed(interactionID: \(id.rawValue.uuidString))"
        case let .failed(id, _):
            return "AgentResponse.failed(interactionID: \(id.rawValue.uuidString), error: <redacted>)"
        }
    }

    public var debugDescription: String { description }
}
