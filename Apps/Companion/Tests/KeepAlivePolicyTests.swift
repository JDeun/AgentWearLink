import XCTest

final class KeepAlivePolicyTests: XCTestCase {
    private func run(
        wants: Bool = true, session: Bool = false, glasses: Bool = false, active: Bool = false, since: TimeInterval? = nil
    ) -> Bool {
        KeepAlivePolicy.shouldRun(
            wantsListening: wants, voiceSessionActive: session, glassesConnected: glasses,
            appActive: active, sinceGlassesSeen: since
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
}
