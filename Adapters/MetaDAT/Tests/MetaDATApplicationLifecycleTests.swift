import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATApplicationLifecycleTests: XCTestCase {
    func testPublishesInitialAndDistinctHostPhases() async throws {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let phases = await lifecycle.phases()
        var iterator = phases.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, MetaDATApplicationPhase.foreground)
        await lifecycle.transition(to: .background)
        let background = await iterator.next()
        XCTAssertEqual(background, MetaDATApplicationPhase.background)

        // Repeating the same host callback must not manufacture another state edge.
        await lifecycle.transition(to: .background)
        let current = await lifecycle.currentPhase
        XCTAssertEqual(current, MetaDATApplicationPhase.background)
    }
    func testPhaseStreamCoalescesBurstToNewestState() async {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let phases = lifecycle.phases()
        var iterator = phases.makeAsyncIterator()

        // Consume the installation value so subsequent transitions exercise
        // only the single-slot coalescing buffer.
        let initial = await iterator.next()
        XCTAssertEqual(initial, .foreground)

        await lifecycle.transition(to: .background)
        await lifecycle.transition(to: .foreground)

        let latest = await iterator.next()
        XCTAssertEqual(latest, .foreground)
    }

    func testForegroundReadinessRequiresFreshReacquisitionAfterBackground() async {
        let readiness = MetaDATForegroundReadiness()

        await readiness.handle(.background)
        let staleState = await readiness.state
        XCTAssertEqual(staleState, .stale)

        await readiness.handle(.foreground)
        let reacquiringState = await readiness.state
        XCTAssertEqual(reacquiringState, .reacquiring)

        // Duplicate foreground callbacks must not manufacture a fresh state.
        await readiness.handle(.foreground)
        let duplicateForegroundState = await readiness.state
        XCTAssertEqual(duplicateForegroundState, .reacquiring)

        await readiness.markReacquired()
        let freshState = await readiness.state
        XCTAssertEqual(freshState, .fresh)

        // Repeated completion is idempotent and cannot replay prior work.
        await readiness.markReacquired()
        let repeatedFreshState = await readiness.state
        XCTAssertEqual(repeatedFreshState, .fresh)
    }

    func testForegroundWithoutBackgroundDoesNotTriggerReacquisition() async {
        let readiness = MetaDATForegroundReadiness()

        await readiness.handle(.foreground)

        let state = await readiness.state
        XCTAssertEqual(state, .fresh)
    }

}
