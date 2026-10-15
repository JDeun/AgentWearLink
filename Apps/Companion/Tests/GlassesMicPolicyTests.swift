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
