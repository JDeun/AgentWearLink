import Foundation

public struct InteractionID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum InteractionEvent: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case sessionStarted(InteractionID)
    case text(InteractionID, String)
    case invocation(InteractionID, String?)
    case interrupted(InteractionID)
    case turnCompleted(InteractionID)
    case sessionEnded(InteractionID)
    case failed(InteractionID?, AWLError)

    public var interactionID: InteractionID? {
        switch self {
        case let .sessionStarted(id),
             let .text(id, _),
             let .invocation(id, _),
             let .interrupted(id),
             let .turnCompleted(id),
             let .sessionEnded(id):
            return id
        case let .failed(id, _):
            return id
        }
    }

    public var description: String {
        switch self {
        case let .sessionStarted(id):
            return "InteractionEvent.sessionStarted(interactionID: \(id.rawValue.uuidString))"
        case let .text(id, text):
            return "InteractionEvent.text(interactionID: \(id.rawValue.uuidString), textBytes: \(text.utf8.count))"
        case let .invocation(id, phrase):
            let phraseDescription = phrase.map { String($0.utf8.count) } ?? "nil"
            return "InteractionEvent.invocation(interactionID: \(id.rawValue.uuidString), phraseBytes: \(phraseDescription))"
        case let .interrupted(id):
            return "InteractionEvent.interrupted(interactionID: \(id.rawValue.uuidString))"
        case let .turnCompleted(id):
            return "InteractionEvent.turnCompleted(interactionID: \(id.rawValue.uuidString))"
        case let .sessionEnded(id):
            return "InteractionEvent.sessionEnded(interactionID: \(id.rawValue.uuidString))"
        case let .failed(id, _):
            let idDescription = id?.rawValue.uuidString ?? "nil"
            return "InteractionEvent.failed(interactionID: \(idDescription), error: <redacted>)"
        }
    }

    public var debugDescription: String { description }
}

public enum AWLError: Error, Sendable, Equatable {
    case authentication
    case capabilityUnavailable(String)
    case device(String)
    case transport(String)
    case agent(String)
    case overloaded(String)
    case timeout
    case cancelled
}


extension InteractionEvent {
    /// An ID-less device failure means the active device/session generation is
    /// no longer usable. Other ID-less failures remain non-terminal diagnostics.
    var isTerminalGlobalDeviceFailure: Bool {
        guard case let .failed(id, error) = self, id == nil else {
            return false
        }
        guard case .device = error else {
            return false
        }
        return true
    }
}
