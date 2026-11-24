import XCTest

final class KeepAlivePolicyTests: XCTestCase {
    private func run(
        wants: Bool = true, session: Bool = false, glasses: Bool = false, active: Bool = false,
        since: TimeInterval? = nil, anchored: Bool = true
    ) -> Bool {
        KeepAlivePolicy.shouldRun(
            wantsListening: wants, voiceSessionActive: session, glassesConnected: glasses,
            appActive: active, sinceGlassesSeen: since, wakeAnchored: anchored
        )
    }

    func testRunsWhileThereIsSomethingToKeepAlive() {
        XCTAssertTrue(run(session: true))
        XCTAssertTrue(run(glasses: true))
        XCTAssertTrue(run(active: true))
    }

    func testStopsAfterTheGraceWithoutGlasses() {
        XCTAssertTrue(run(since: 60))
        XCTAssertFalse(run(since: KeepAlivePolicy.graceWithoutGlasses + 1))
        XCTAssertFalse(run(since: nil), "never saw glasses in this launch, in the background")
    }

    func testNeverRunsWhenListeningIsOff() {
        XCTAssertFalse(run(wants: false, session: true, glasses: true, active: true))
    }

    // Finding 3: with nothing anchored, nothing would wake the app again.
    func testKeepsRunningWithoutAWakeAnchor() {
        XCTAssertTrue(run(since: KeepAlivePolicy.graceWithoutGlasses + 1, anchored: false))
        XCTAssertTrue(run(since: nil, anchored: false))
        XCTAssertFalse(run(wants: false, anchored: false))
    }

    // Finding 2: a long session with no device event must not expire the clock.
    func testConnectedGlassesOrALiveSessionRefreshTheGraceClock() {
        let old = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 3_600)
        XCTAssertEqual(KeepAlivePolicy.lastSeen(previous: old, now: now, glassesConnected: true, voiceSessionLive: false), now)
        XCTAssertEqual(KeepAlivePolicy.lastSeen(previous: old, now: now, glassesConnected: false, voiceSessionLive: true), now)
        XCTAssertEqual(KeepAlivePolicy.lastSeen(previous: old, now: now, glassesConnected: false, voiceSessionLive: false), old)
        XCTAssertNil(KeepAlivePolicy.lastSeen(previous: nil, now: now, glassesConnected: false, voiceSessionLive: false))
    }

    // Finding 14: say what actually happened.
    func testOffReasonSaysWhatHappened() {
        XCTAssertEqual(KeepAlivePolicy.offReason(wantsListening: false, sinceGlassesSeen: 10), "keep-alive off: listening off")
        XCTAssertEqual(KeepAlivePolicy.offReason(wantsListening: true, sinceGlassesSeen: nil),
                       "keep-alive off: in the background, no glasses seen since launch")
        XCTAssertEqual(KeepAlivePolicy.offReason(wantsListening: true, sinceGlassesSeen: 310), "keep-alive off: no glasses for 5 min")
        XCTAssertEqual(KeepAlivePolicy.offReason(wantsListening: true, sinceGlassesSeen: 3_700), "keep-alive off: no glasses for 61 min")
    }
}

final class WakeAnchorBackoffTests: XCTestCase {
    func testFailedConnectsBackOffFromFiveSecondsToFiveMinutes() {
        XCTAssertEqual(WakeAnchorBackoff.delay(afterFailures: 0), 0)
        XCTAssertEqual(WakeAnchorBackoff.delay(afterFailures: 1), 5)
        XCTAssertEqual(WakeAnchorBackoff.delay(afterFailures: 2), 10)
        XCTAssertEqual(WakeAnchorBackoff.delay(afterFailures: 4), 40)
        XCTAssertEqual(WakeAnchorBackoff.delay(afterFailures: 7), 300)
        XCTAssertEqual(WakeAnchorBackoff.delay(afterFailures: 1_000), 300)
    }

    func testAnchorsOnlyWhileListeningIsWantedAfterSetup() {
        XCTAssertTrue(WakeAnchorBackoff.shouldAnchor(setupCompleted: true, listenEnabled: true))
        XCTAssertFalse(WakeAnchorBackoff.shouldAnchor(setupCompleted: false, listenEnabled: true))
        XCTAssertFalse(WakeAnchorBackoff.shouldAnchor(setupCompleted: true, listenEnabled: false))
    }
}

final class SettingsResetForgetsAnchorTests: XCTestCase {
    func testResetForgetsTheAnchoredGlasses() {
        let defaults = UserDefaults(suiteName: "awl.test.anchor.\(UUID().uuidString)")!
        defaults.set(["00000000-0000-0000-0000-000000000001"], forKey: CompanionSettingsStore.Key.glassesPeripherals)
        CompanionSettingsStore(defaults: defaults).reset()
        XCTAssertNil(defaults.object(forKey: CompanionSettingsStore.Key.glassesPeripherals))
    }
}
