import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATApplicationLifecycleTests: XCTestCase {
    func testPublishesInitialAndDistinctHostPhases() async throws {
        let lifecycle = MetaDATApplicationLifecycle()
        let phases = await lifecycle.phases()
        var iterator = phases.makeAsyncIterator()

        XCTAssertEqual(await iterator.next(), .foreground)
        await lifecycle.transition(to: .background)
        XCTAssertEqual(await iterator.next(), .background)

        // Repeating the same host callback must not manufacture another state edge.
        await lifecycle.transition(to: .background)
        XCTAssertEqual(await lifecycle.currentPhase, .background)
    }
}
