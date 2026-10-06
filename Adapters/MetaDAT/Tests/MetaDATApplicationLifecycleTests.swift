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
}
