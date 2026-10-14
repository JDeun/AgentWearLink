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
}
