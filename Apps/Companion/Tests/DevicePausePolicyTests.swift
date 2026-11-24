import XCTest

final class DevicePausePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func inputs(
        pausedAt offset: TimeInterval? = 0, worn: Bool = true, call: Bool = false,
        held: Bool = false, wanted: Bool = true
    ) -> DevicePausePolicy.Inputs {
        .init(pausedSince: offset.map { t0.addingTimeInterval($0) }, worn: worn, callActive: call,
              held: held, listeningWanted: wanted)
    }

    func testWaitsTheGraceThenRecreates() {
        var policy = DevicePausePolicy()
        XCTAssertEqual(policy.decide(inputs(), now: t0.addingTimeInterval(1)),
                       .wait(until: t0.addingTimeInterval(6)))
        XCTAssertEqual(policy.decide(inputs(), now: t0.addingTimeInterval(6)), .recreateNow)
    }

    func testNotPausedOrNotWantedNeverRecreates() {
        var policy = DevicePausePolicy()
        XCTAssertEqual(policy.decide(inputs(pausedAt: nil), now: t0), .dontRecreate(.notPaused))
        XCTAssertEqual(policy.decide(inputs(wanted: false), now: t0.addingTimeInterval(60)), .dontRecreate(.notWanted))
    }

    func testDoffFoldCallAndHoldAreNotTaps() {
        var policy = DevicePausePolicy()
        let late = t0.addingTimeInterval(60)
        XCTAssertEqual(policy.decide(inputs(worn: false), now: late), .dontRecreate(.notWorn))
        XCTAssertEqual(policy.decide(inputs(call: true), now: late), .dontRecreate(.call))
        XCTAssertEqual(policy.decide(inputs(held: true), now: late), .dontRecreate(.held))
        XCTAssertTrue(policy.recreates.isEmpty)
    }

    func testCueOnlyForATapLikePause() {
        XCTAssertTrue(DevicePausePolicy.cuesPause(inputs()))
        XCTAssertFalse(DevicePausePolicy.cuesPause(inputs(pausedAt: nil)))
        XCTAssertFalse(DevicePausePolicy.cuesPause(inputs(worn: false)))
        XCTAssertFalse(DevicePausePolicy.cuesPause(inputs(call: true)))
        XCTAssertFalse(DevicePausePolicy.cuesPause(inputs(held: true)))
        XCTAssertFalse(DevicePausePolicy.cuesPause(inputs(wanted: false)))
    }

    func testRepauseSoonAfterARecreateWaitsLonger() {
        var policy = DevicePausePolicy()
        policy.recreated(at: t0)
        policy.recreatedListening(at: t0.addingTimeInterval(4))
        // Paused again 10 s after listening resumed: 20 s grace.
        let pausedAgain = 14.0
        XCTAssertEqual(policy.decide(inputs(pausedAt: pausedAgain), now: t0.addingTimeInterval(pausedAgain + 6)),
                       .wait(until: t0.addingTimeInterval(pausedAgain + 20)))
        XCTAssertEqual(policy.decide(inputs(pausedAt: pausedAgain), now: t0.addingTimeInterval(pausedAgain + 20)),
                       .recreateNow)
        // Paused 40 s after: back to the normal grace.
        XCTAssertEqual(policy.decide(inputs(pausedAt: 44), now: t0.addingTimeInterval(44)),
                       .wait(until: t0.addingTimeInterval(50)))
    }

    func testBudgetStopsRecreatingUntilAFreshEvent() {
        var policy = DevicePausePolicy()
        for minute in 0..<5 { policy.recreated(at: t0.addingTimeInterval(Double(minute) * 60)) }
        let now = t0.addingTimeInterval(5 * 60)
        XCTAssertEqual(policy.decide(inputs(pausedAt: 290), now: now), .dontRecreate(.budgetExhausted))
        XCTAssertTrue(policy.exhausted)
        // Still exhausted after the window has passed: only a fresh event clears it.
        XCTAssertEqual(policy.decide(inputs(pausedAt: 3000), now: t0.addingTimeInterval(3010)),
                       .dontRecreate(.budgetExhausted))
        policy.freshEvent()
        XCTAssertEqual(policy.decide(inputs(pausedAt: 3000), now: t0.addingTimeInterval(3010)), .recreateNow)
    }

    func testOldRecreatesLeaveTheBudget() {
        var policy = DevicePausePolicy()
        for minute in 0..<4 { policy.recreated(at: t0.addingTimeInterval(Double(minute) * 60)) }
        policy.recreated(at: t0.addingTimeInterval(100))
        // 11 minutes later only none count.
        XCTAssertEqual(policy.decide(inputs(pausedAt: 700), now: t0.addingTimeInterval(800)), .recreateNow)
        XCTAssertEqual(policy.recreates.count, 0)
    }
}
