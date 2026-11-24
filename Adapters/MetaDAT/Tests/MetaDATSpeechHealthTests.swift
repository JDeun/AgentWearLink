import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechHealthTests: XCTestCase {
    func testOnlyStartedSessionAndStartedHealthyAttachmentAreSDKReady() {
        for phase: MetaDATSpeechHealth.Phase in [.detached, .starting, .started, .stopping, .stopped] {
            for session in [false, true] {
                for delivery in [false, true] {
                    let health = MetaDATSpeechHealth(sessionStarted: session, phase: phase, deliveryActive: delivery)
                    XCTAssertEqual(health.isSDKReady, session && phase == .started && delivery)
                }
            }
        }
    }

    func testStartedWithoutCallbacksIsNotProofOfRecognition() {
        let health = MetaDATSpeechHealth(sessionStarted: true, phase: .started, deliveryActive: true)
        XCTAssertTrue(health.isSDKReady)
        XCTAssertEqual(health.callbackEvidence(freshness: .seconds(5)), .notObserved)
    }

    func testEmptyRecentAndStaleEvidenceRemainDistinct() {
        let now = ContinuousClock.now
        let recent = now.advanced(by: .seconds(-1))
        let older = now.advanced(by: .seconds(-10))
        let empty = MetaDATSpeechHealth(sessionStarted: true, phase: .started, deliveryActive: true, lastCallbackAt: recent, lastNonEmptyCallbackAt: older)
        let nonEmpty = MetaDATSpeechHealth(sessionStarted: true, phase: .started, deliveryActive: true, lastCallbackAt: recent, lastNonEmptyCallbackAt: recent)
        let stale = MetaDATSpeechHealth(sessionStarted: true, phase: .started, deliveryActive: true, lastCallbackAt: older, lastNonEmptyCallbackAt: older)
        XCTAssertEqual(empty.callbackEvidence(now: now, freshness: .seconds(5)), .recentCallbackOnly)
        XCTAssertEqual(nonEmpty.callbackEvidence(now: now, freshness: .seconds(5)), .recentNonEmptyCallback)
        XCTAssertEqual(stale.callbackEvidence(now: now, freshness: .seconds(5)), .stale)
        // Absence of recent callbacks is ambiguous, not an automatic fault.
        XCTAssertTrue(stale.isSDKReady)
    }

    func testPausedSessionOrRetiredDeliveryOverridesOldCallbackEvidence() {
        let now = ContinuousClock.now
        let paused = MetaDATSpeechHealth(sessionStarted: false, phase: .started, deliveryActive: true, lastCallbackAt: now, lastNonEmptyCallbackAt: now)
        let retired = MetaDATSpeechHealth(sessionStarted: true, phase: .started, deliveryActive: false, lastCallbackAt: now, lastNonEmptyCallbackAt: now)
        for health in [paused, retired] {
            XCTAssertFalse(health.isSDKReady)
            XCTAssertEqual(health.callbackEvidence(now: now, freshness: .seconds(5)), .unavailable)
        }
    }
}
