import XCTest

final class GlassesMicPolicyTests: XCTestCase {
    func testRealErrorsBackOffFromHalfASecondToTenSeconds() {
        XCTAssertEqual(GlassesMicRetry.delay(afterErrors: 0), 0)
        XCTAssertEqual(GlassesMicRetry.delay(afterErrors: 1), 0.5)
        XCTAssertEqual(GlassesMicRetry.delay(afterErrors: 2), 1)
        XCTAssertEqual(GlassesMicRetry.delay(afterErrors: 5), 8)
        XCTAssertEqual(GlassesMicRetry.delay(afterErrors: 6), 10)
        XCTAssertEqual(GlassesMicRetry.delay(afterErrors: 10_000), 10)
    }

    // Finding 1: a cancelled task's callback must not restart the new one,
    // and a stale partial must not be adopted (duplicate request).
    func testOnlyTheCurrentTasksCallbacksCount() {
        XCTAssertTrue(GlassesMicRetry.isCurrent(callbackGeneration: 3, current: 3, running: true))
        XCTAssertFalse(GlassesMicRetry.isCurrent(callbackGeneration: 2, current: 3, running: true))
        XCTAssertFalse(GlassesMicRetry.isCurrent(callbackGeneration: 3, current: 3, running: false))
    }

    func testSilenceEndsATaskWithoutBackingOff() {
        XCTAssertTrue(GlassesMicRetry.isQuietEnd(domain: "kAFAssistantErrorDomain", code: 1110, taskAge: 30))
        XCTAssertFalse(GlassesMicRetry.isQuietEnd(domain: "kAFAssistantErrorDomain", code: 1110, taskAge: 0.2), "dies at once: back off")
        XCTAssertFalse(GlassesMicRetry.isQuietEnd(domain: "kAFAssistantErrorDomain", code: 1101, taskAge: 30))
        XCTAssertFalse(GlassesMicRetry.isQuietEnd(domain: nil, code: nil, taskAge: 30))
    }
}

final class HFPListeningLeaseTests: XCTestCase {
    func testOnlyExplicitBoundedDurationsAreAccepted() {
        let now = ContinuousClock.now
        for seconds in HFPListeningLease.allowedSeconds {
            let lease = HFPListeningLease(seconds: seconds, now: now)
            XCTAssertEqual(lease?.deadline, now.advanced(by: .seconds(seconds)))
        }
        for seconds in [-1, 0, 1, 301, 86_400] {
            XCTAssertNil(HFPListeningLease(seconds: seconds, now: now))
        }
    }

    func testSilenceExpiresButActivityCannotExtendHardDeadline() throws {
        let now = ContinuousClock.now
        var lease = try XCTUnwrap(HFPListeningLease(seconds: 60, now: now))
        XCTAssertNil(lease.end(at: now.advanced(by: .seconds(29)), routeAvailable: true, competingAudio: false))
        XCTAssertEqual(lease.end(at: now.advanced(by: .seconds(30)), routeAvailable: true, competingAudio: false), .inactive)
        lease.noteActivity(at: now.advanced(by: .seconds(25)))
        lease.noteActivity(at: now.advanced(by: .seconds(50)))
        XCTAssertNil(lease.end(at: now.advanced(by: .seconds(59)), routeAvailable: true, competingAudio: false))
        XCTAssertEqual(lease.end(at: now.advanced(by: .seconds(60)), routeAvailable: true, competingAudio: false), .expired)
        lease.noteActivity(at: now.advanced(by: .seconds(61)))
        XCTAssertEqual(lease.lastActivity, now.advanced(by: .seconds(50)))
    }

    func testRouteLossAndCompetingAudioEndImmediately() throws {
        let now = ContinuousClock.now
        let lease = try XCTUnwrap(HFPListeningLease(seconds: 120, now: now))
        XCTAssertEqual(lease.end(at: now, routeAvailable: false, competingAudio: false), .routeLost)
        XCTAssertEqual(lease.end(at: now, routeAvailable: true, competingAudio: true), .competingAudio)
        XCTAssertNil(lease.end(at: now, routeAvailable: true, competingAudio: false))
    }
}
