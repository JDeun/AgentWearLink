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

    func testBackgroundIsNotOverwrittenByRapidForeground() async {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let phases = lifecycle.phases()
        var iterator = phases.makeAsyncIterator()

        XCTAssertEqual(await iterator.next(), .foreground)
        await lifecycle.transition(to: .background)
        await lifecycle.transition(to: .foreground)

        // Event consumers must see the retirement edge even when the current
        // phase is already foreground again. Fresh state comes from currentPhase.
        XCTAssertEqual(await iterator.next(), .background)
        XCTAssertEqual(await lifecycle.currentPhase, .foreground)
    }

    func testUnconsumedInitialPhaseCannotHideBackground() async {
        let lifecycle = MetaDATApplicationLifecycle(initialPhase: .foreground)
        let phases = lifecycle.phases()
        // Deliberately leave the initial phase queued until both edges occur.
        await lifecycle.transition(to: .background)
        await lifecycle.transition(to: .foreground)

        var iterator = phases.makeAsyncIterator()
        XCTAssertEqual(await iterator.next(), .foreground)
        XCTAssertEqual(await iterator.next(), .background)
        XCTAssertEqual(await lifecycle.currentPhase, .foreground)
    }

    func testForegroundReadinessRequiresFreshReacquisitionAfterBackground() async {
        let readiness = MetaDATForegroundReadiness(initialPhase: .foreground)

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

    func testForegroundColdStartRequiresExplicitReacquisition() async {
        let readiness = MetaDATForegroundReadiness(initialPhase: .foreground)

        let initialState = await readiness.state
        XCTAssertEqual(initialState, .reacquiring)

        await readiness.handle(.foreground)
        let repeatedForegroundState = await readiness.state
        XCTAssertEqual(repeatedForegroundState, .reacquiring)

        await readiness.markReacquired()
        let freshState = await readiness.state
        XCTAssertEqual(freshState, .fresh)
    }

    func testBackgroundColdStartIsNeverFresh() async {
        let readiness = MetaDATForegroundReadiness(initialPhase: .background)

        let initialState = await readiness.state
        XCTAssertEqual(initialState, .stale)

        await readiness.markReacquired()
        let stillStale = await readiness.state
        XCTAssertEqual(stillStale, .stale)

        await readiness.handle(.foreground)
        let foregroundState = await readiness.state
        XCTAssertEqual(foregroundState, .reacquiring)
    }

}
