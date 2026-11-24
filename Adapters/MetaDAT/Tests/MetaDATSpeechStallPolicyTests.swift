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

    func testEmptyOnlyLimitBacksOffAndCaps() {
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit(consecutiveEmptyRestarts: 0, sinceFreshStart: nil), 20)
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit(consecutiveEmptyRestarts: 1, sinceFreshStart: 120), 40)
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit(consecutiveEmptyRestarts: 3, sinceFreshStart: 120), 160)
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit(consecutiveEmptyRestarts: 9, sinceFreshStart: 120), 300)
    }

    func testFreshStartKeepsTwentySeconds() {
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit(consecutiveEmptyRestarts: 4, sinceFreshStart: 10), 20)
        XCTAssertEqual(MetaDATSpeechStallPolicy.emptyOnlyLimit(consecutiveEmptyRestarts: 4, sinceFreshStart: 61), 300)
    }

    func testActionUsesTheGivenLimit() {
        XCTAssertEqual(
            MetaDATSpeechStallPolicy.action(sinceAnyEvent: 0.3, sinceNonEmpty: 30, speechStarted: true,
                                            sessionStarted: true, pausedByHost: false, emptyOnlyLimit: 40),
            .none
        )
        XCTAssertEqual(
            MetaDATSpeechStallPolicy.action(sinceAnyEvent: 0.3, sinceNonEmpty: 41, speechStarted: true,
                                            sessionStarted: true, pausedByHost: false, emptyOnlyLimit: 40),
            .restart(.emptyOnly)
        )
    }

    // One stats line a minute (30 checks of 2 s), not every 10 s.
    func testSpeechStatsAreLoggedOncePerMinute() {
        let logged = (1...300).filter { MetaDATSpeechStallPolicy.shouldLogStats(afterCheck: $0) }
        XCTAssertEqual(logged, [30, 60, 90, 120, 150, 180, 210, 240, 270, 300])
        XCTAssertFalse(MetaDATSpeechStallPolicy.shouldLogStats(afterCheck: 0))
    }

    // MODERATE heat stretches the stats line to every 5 minutes.
    func testReducedWorkStretchesSpeechStats() {
        let logged = (1...300).filter { MetaDATSpeechStallPolicy.shouldLogStats(afterCheck: $0, reduced: true) }
        XCTAssertEqual(logged, [150, 300])
        XCTAssertEqual(MetaDATSpeechStallPolicy.statsSeconds(reduced: false), 60)
        XCTAssertEqual(MetaDATSpeechStallPolicy.statsSeconds(reduced: true), 300)
    }

    func testPostStopRequiresConfirmedStopAndActiveOwnership() {
        func decision(owns: Bool = true, cancelled: Bool = false, paused: Bool = false,
                      session: Bool = true, stopped: Bool = true, beforeDeadline: Bool = true)
            -> MetaDATSpeechStallPolicy.PostStopAction {
            MetaDATSpeechStallPolicy.postStopAction(
                ownsSpeech: owns, cancelled: cancelled, hostPaused: paused, sessionStarted: session,
                speechStopped: stopped, beforeDeadline: beforeDeadline
            )
        }
        XCTAssertEqual(decision(), .start)
        XCTAssertEqual(decision(stopped: false), .wait)
        XCTAssertEqual(decision(owns: false), .abandon)
        XCTAssertEqual(decision(cancelled: true), .abandon)
        XCTAssertEqual(decision(paused: true), .abandon)
        XCTAssertEqual(decision(session: false), .abandon)
        XCTAssertEqual(decision(stopped: false, beforeDeadline: false), .abandon)
        XCTAssertEqual(decision(stopped: true, beforeDeadline: false), .abandon)
    }

    func testNoEventRecoveryHasFiniteBudget() {
        XCTAssertTrue(MetaDATSpeechStallPolicy.canRecoverNoEvents(attempts: 0))
        XCTAssertTrue(MetaDATSpeechStallPolicy.canRecoverNoEvents(attempts: 2))
        XCTAssertFalse(MetaDATSpeechStallPolicy.canRecoverNoEvents(attempts: 3))
        XCTAssertFalse(MetaDATSpeechStallPolicy.canRecoverNoEvents(attempts: 100))
    }

}
