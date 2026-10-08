import Foundation

public struct MetaDATVoiceReopenPolicy: Sendable, Equatable {
    public let delays: [Duration]

    public init(
        // Mock transport and Meta AI voice-channel negotiation can become
        // ready seconds after registration and BLE link transitions. Keep
        // startup retries bounded (15.75s aggregate) rather than expiring
        // before the voice channel can attach on slower devices.
        delays: [Duration] = [
            .milliseconds(250), .milliseconds(500), .seconds(1),
            .seconds(2), .seconds(4), .seconds(8)
        ]
    ) {
        precondition(delays.allSatisfy { $0 >= .zero })
        self.delays = delays
    }

    public func delay(afterFailure attempt: Int) -> Duration? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}
