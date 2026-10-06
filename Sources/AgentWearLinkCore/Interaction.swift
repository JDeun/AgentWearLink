import Foundation

public struct InteractionID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum InteractionEvent: Sendable, Equatable {
    case sessionStarted(InteractionID)
    case text(InteractionID, String)
    case invocation(InteractionID, String?)
    case interrupted(InteractionID)
    case sessionEnded(InteractionID)
    case failed(InteractionID?, AWLError)

    public var interactionID: InteractionID? {
        switch self {
        case let .sessionStarted(id),
             let .text(id, _),
             let .invocation(id, _),
             let .interrupted(id),
             let .sessionEnded(id):
            return id
        case let .failed(id, _):
            return id
        }
    }
}

public enum AWLError: Error, Sendable, Equatable {
    case authentication
    case capabilityUnavailable(String)
    case device(String)
    case transport(String)
    case agent(String)
    case timeout
    case cancelled
}
