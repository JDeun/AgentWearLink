import XCTest
@testable import AgentWearLinkCore

private actor RecordedEvents {
    var values: [InteractionEvent] = []

    func append(_ event: InteractionEvent) {
        values.append(event)
    }
}

private actor StubAgent: AgentAdapter {
    private(set) var requestCount = 0
    private(set) var cancelled: [InteractionID] = []

    func connect() async throws {}
    func disconnect() async {}

    func responses(
        for event: InteractionEvent
    ) -> AsyncThrowingStream<InteractionEvent, Error> {
        requestCount += 1
        let id = event.interactionID!

        return AsyncThrowingStream { continuation in
            continuation.yield(.text(id, "response"))
            continuation.finish()
        }
    }

    func cancel(interactionID: InteractionID) async {
        cancelled.append(interactionID)
    }

    func requests() -> Int { requestCount }
    func cancellations() -> [InteractionID] { cancelled }
}

final class InteractionCoordinatorTests: XCTestCase {
    func testDuplicateRequestForInteractionIsSuppressed() async throws {
        let agent = StubAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let id = InteractionID()
        let event = InteractionEvent.text(id, "hello")

        await coordinator.handle(event)
        await coordinator.handle(event)

        try await Task.sleep(for: .milliseconds(20))

        let count = await agent.requests()
        XCTAssertEqual(count, 1)
    }

    func testInterruptionCancelsAgentInteraction() async {
        let agent = StubAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let id = InteractionID()
        await coordinator.handle(.text(id, "hello"))
        await coordinator.handle(.interrupted(id))

        let cancellations = await agent.cancellations()
        XCTAssertEqual(cancellations, [id])
    }
}
