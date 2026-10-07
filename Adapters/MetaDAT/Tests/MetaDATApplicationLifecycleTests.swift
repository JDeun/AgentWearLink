import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATApplicationLifecycleTests: XCTestCase {
    func testPublishesInitialAndDistinctHostPhases() async throws {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let phases = lifecycle.phases()
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
    func testImmediateTransitionAfterSubscriptionCannotBeLost() async {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let phases = lifecycle.phases()

        await lifecycle.transition(to: .background)

        var iterator = phases.makeAsyncIterator()
        let firstVisible = await iterator.next()
        XCTAssertEqual(firstVisible, .background)
    }

    func testReplacementSubscriptionOwnsFutureLifecycleTransitions() async {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let first = lifecycle.phases()
        var firstIterator = first.makeAsyncIterator()
        let firstInitial = await firstIterator.next()
        XCTAssertEqual(firstInitial, .foreground)

        let replacement = lifecycle.phases()
        var replacementIterator = replacement.makeAsyncIterator()

        let firstTerminal = await firstIterator.next()
        XCTAssertNil(firstTerminal)
        let replacementInitial = await replacementIterator.next()
        XCTAssertEqual(replacementInitial, .foreground)

        await lifecycle.transition(to: .background)
        let replacementBackground = await replacementIterator.next()
        XCTAssertEqual(replacementBackground, .background)
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

    func testPublishesBackgroundColdStartAsInitialPhase() async {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .background)
        var iterator = lifecycle.phases().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, .background)
        let current = await lifecycle.currentPhase
        XCTAssertEqual(current, .background)
    }

    func testForegroundReadinessRequiresFreshReacquisitionAfterBackground() async {
        let readiness = MetaDATForegroundReadiness(initialPhase: .foreground)

        // Construction is not evidence that private-media state is fresh.
        let initialState = await readiness.state
        XCTAssertEqual(initialState, .reacquiring)
        await readiness.markReacquired()
        let initialFreshState = await readiness.state
        XCTAssertEqual(initialFreshState, .fresh)

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

    func testForegroundStartRequiresExplicitReacquisitionBeforeFresh() async {
        let readiness = MetaDATForegroundReadiness(initialPhase: .foreground)

        let initial = await readiness.state
        XCTAssertEqual(initial, .reacquiring)

        await readiness.handle(.foreground)
        let duplicateForeground = await readiness.state
        XCTAssertEqual(duplicateForeground, .reacquiring)

        await readiness.markReacquired()
        let fresh = await readiness.state
        XCTAssertEqual(fresh, .fresh)
    }

    func testBackgroundColdStartStaysStaleUntilForegroundReacquisition() async {
        let readiness = MetaDATForegroundReadiness(initialPhase: .background)

        let initial = await readiness.state
        XCTAssertEqual(initial, .stale)

        await readiness.handle(.foreground)
        let reacquiring = await readiness.state
        XCTAssertEqual(reacquiring, .reacquiring)

        await readiness.markReacquired()
        let fresh = await readiness.state
        XCTAssertEqual(fresh, .fresh)
    }

}
