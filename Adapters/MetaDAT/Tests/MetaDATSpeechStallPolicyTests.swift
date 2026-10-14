import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechStallPolicyTests: XCTestCase {
    private func action(
        any: TimeInterval?, nonEmpty: TimeInterval?,
        speech: Bool = true, session: Bool = true, paused: Bool = false
    ) -> MetaDATSpeechStallPolicy.Action {
        MetaDATSpeechStallPolicy.action(
            sinceAnyEvent: any, sinceNonEmpty: nonEmpty,
            speechStarted: speech, sessionStarted: session, pausedByHost: paused
        )
    }

    func testHealthyListeningDoesNothing() {
        XCTAssertEqual(action(any: 0.3, nonEmpty: 15), .none)
        XCTAssertEqual(action(any: nil, nonEmpty: nil), .none)
    }

    func testNoEventsForFourSecondsRestarts() {
        XCTAssertEqual(action(any: 4.1, nonEmpty: 4.1), .restart(.noEvents))
        XCTAssertEqual(action(any: 4.0, nonEmpty: 4.0), .none)
    }

    func testOnlyEmptyTranscriptsForTwentySecondsRestarts() {
        XCTAssertEqual(action(any: 0.3, nonEmpty: 20.5), .restart(.emptyOnly))
        XCTAssertEqual(action(any: 0.3, nonEmpty: 19.9), .none)
    }

    func testNeverFightsTheHostOrAPausedSession() {
        XCTAssertEqual(action(any: 60, nonEmpty: 60, paused: true), .none)
        XCTAssertEqual(action(any: 60, nonEmpty: 60, session: false), .none)
        XCTAssertEqual(action(any: 60, nonEmpty: 60, speech: false), .none)
    }

    func testSpeechStoppedDuringSessionPauseRestartsOnResume() {
        XCTAssertTrue(MetaDATSpeechStallPolicy.shouldRestartAfterSessionResumes(speechStopped: true, pausedByHost: false))
        XCTAssertFalse(MetaDATSpeechStallPolicy.shouldRestartAfterSessionResumes(speechStopped: true, pausedByHost: true))
        XCTAssertFalse(MetaDATSpeechStallPolicy.shouldRestartAfterSessionResumes(speechStopped: false, pausedByHost: false))
    }

    func testThresholds() {
        XCTAssertEqual(MetaDATSpeechStallPolicy.noEventLimit, 4)
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit, 20)
    }
}
