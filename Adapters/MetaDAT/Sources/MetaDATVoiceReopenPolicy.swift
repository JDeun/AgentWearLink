import Foundation
public struct MetaDATVoiceReopenPolicy: Sendable, Equatable {
    public let delays: [Duration]
    public init(delays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1)]) { self.delays = delays }
    public func delay(afterFailure attempt: Int) -> Duration? { guard attempt >= 0, attempt < delays.count else { return nil }; return delays[attempt] }
}
