import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechRestartPolicyTests: XCTestCase {
    func testUnrequestedStopRestartsUpToTheLimit() {
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .stopped, attempts: 0), .restart(attempt: 1))
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .stopped, attempts: 2), .restart(attempt: 3))
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .stopped, attempts: 3), .giveUp)
    }

    func testStartedResetsTheBudgetAndOtherStatesDoNothing() {
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .started, attempts: 3), .resetAttempts)
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .transitioning, attempts: 1), .none)
    }

    func testRestartMatchesMetaSampleCadence() {
        // BirdSpotter revives Speech three times, 750 ms apart.
        XCTAssertEqual(MetaDATSpeechRestartPolicy.limit, 3)
        XCTAssertEqual(MetaDATSpeechRestartPolicy.delay, .milliseconds(750))
    }

    func testAPausedStopIsNeverRestarted() {
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .stopped, attempts: 0, paused: true), .none)
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .started, attempts: 2, paused: true), .resetAttempts)
        XCTAssertEqual(MetaDATSpeechRestartPolicy.action(for: .stopped, attempts: 0, paused: false), .restart(attempt: 1))
    }

    // Speech that keeps stopping by itself may be shed by the device (power
    // or heat); keep reviving it, but stop fighting at full speed.
    func testRepeatedSelfStopsBackOff() {
        XCTAssertEqual(MetaDATSpeechRestartPolicy.restartDelay(recentUnrequestedStops: 1), .milliseconds(750))
        XCTAssertEqual(MetaDATSpeechRestartPolicy.restartDelay(recentUnrequestedStops: 3), .milliseconds(750))
        XCTAssertEqual(MetaDATSpeechRestartPolicy.restartDelay(recentUnrequestedStops: 4), .seconds(60))
        XCTAssertEqual(MetaDATSpeechRestartPolicy.restartDelay(recentUnrequestedStops: 6), .seconds(300))
    }

    func testOnlyStopsInsideTheWindowCount() {
        let now: TimeInterval = 10_000
        let stops: [TimeInterval] = [now - 700, now - 500, now - 30, now - 5]
        XCTAssertEqual(MetaDATSpeechRestartPolicy.recent(stops, now: now), [now - 500, now - 30, now - 5])
    }
}
