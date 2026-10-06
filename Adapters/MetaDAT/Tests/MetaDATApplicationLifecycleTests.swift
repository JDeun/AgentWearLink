import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATApplicationLifecycleTests: XCTestCase {
    func testPublishesInitialAndDistinctHostPhases() async throws {
        let lifecycle = MetaDATApplicationLifecycle()
        let phases = await lifecycle.phases()
        var iterator = phases.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, .foreground)
        await lifecycle.transition(to: .background)
        let background = await iterator.next()
        XCTAssertEqual(background, .background)

        // Repeating the same host callback must not manufacture another state edge.
        await lifecycle.transition(to: .background)
        let current = await lifecycle.currentPhase
        XCTAssertEqual(current, .background)
    }
    func testForegroundReadinessRequiresFreshReacquisitionAfterBackground() async {
        let readiness = MetaDATForegroundReadiness()

        await readiness.handle(.background)
        XCTAssertEqual(await readiness.state, .stale)

        await readiness.handle(.foreground)
        XCTAssertEqual(await readiness.state, .reacquiring)

        // Duplicate foreground callbacks must not manufacture a fresh state.
        await readiness.handle(.foreground)
        XCTAssertEqual(await readiness.state, .reacquiring)

        await readiness.markReacquired()
        XCTAssertEqual(await readiness.state, .fresh)

        // Repeated completion is idempotent and cannot replay prior work.
        await readiness.markReacquired()
        XCTAssertEqual(await readiness.state, .fresh)
    }

    func testForegroundWithoutBackgroundDoesNotTriggerReacquisition() async {
        let readiness = MetaDATForegroundReadiness()

        await readiness.handle(.foreground)

        XCTAssertEqual(await readiness.state, .fresh)
    }

}
