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
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(request.interactionID, "response"))
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
        await coordinator.handle(.text(id, "hello"))
        await coordinator.handle(.text(id, "hello"))

        try await Task.sleep(for: .milliseconds(20))
        let requestCount = await agent.requests()
        XCTAssertEqual(requestCount, 1)
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

    func testCompletedInteractionCanBeSubmittedAgain() async throws {
        let agent = StubAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let id = InteractionID()
        await coordinator.handle(.text(id, "first"))
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.handle(.text(id, "second"))
        try await Task.sleep(for: .milliseconds(20))

        let requestCount = await agent.requests()
        XCTAssertEqual(requestCount, 2)
    }

    func testAgentResponseIsNormalizedBackToInteractionEvent() async throws {
        let agent = StubAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let id = InteractionID()
        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertTrue(events.contains(.text(id, "response")))
    }
}


private actor DelayedFirstAgent: AgentAdapter {
    private(set) var requestCount = 0
    private var firstGate: CheckedContinuation<Void, Never>?
    private var continuations: [AsyncThrowingStream<AgentResponse, Error>.Continuation] = []

    func connect() async throws {}
    func disconnect() async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        requestCount += 1
        let ordinal = requestCount

        if ordinal == 1 {
            await withCheckedContinuation { continuation in
                firstGate = continuation
            }
        }

        var captured: AsyncThrowingStream<AgentResponse, Error>.Continuation?
        let stream = AsyncThrowingStream<AgentResponse, Error> { continuation in
            captured = continuation
        }
        if let captured {
            continuations.append(captured)
        }
        return stream
    }

    func cancel(interactionID: InteractionID) async {}

    func requests() -> Int { requestCount }

    func releaseFirst() {
        firstGate?.resume()
        firstGate = nil
    }

    func finishAll() {
        for continuation in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }
}

private actor TerminalThenLateAgent: AgentAdapter {
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(request.interactionID))
            continuation.yield(.textDelta(request.interactionID, "late"))
            continuation.finish()
        }
    }
}

private actor TypedFailureAgent: AgentAdapter {
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AWLError.timeout)
        }
    }
}

extension InteractionCoordinatorTests {
    func testCancelledOldGenerationCannotRemoveReplacementTask() async throws {
        let agent = DelayedFirstAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "first"))
        try await Task.sleep(for: .milliseconds(20))

        await coordinator.handle(.interrupted(id))
        await coordinator.handle(.text(id, "second"))
        try await Task.sleep(for: .milliseconds(20))

        let afterReplacement = await agent.requests()
        XCTAssertEqual(afterReplacement, 2)

        await agent.releaseFirst()
        try await Task.sleep(for: .milliseconds(20))

        await coordinator.handle(.text(id, "third"))
        try await Task.sleep(for: .milliseconds(20))

        let finalCount = await agent.requests()
        XCTAssertEqual(finalCount, 2)

        await coordinator.cancelAll()
        await agent.finishAll()
    }

    func testTerminalResponseStopsLateDeltas() async throws {
        let agent = TerminalThenLateAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertTrue(events.contains(.sessionEnded(id)))
        XCTAssertFalse(events.contains(.text(id, "late")))
    }

    func testTypedAgentErrorIsPreserved() async throws {
        let agent = TypedFailureAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertTrue(events.contains(.failed(id, .timeout)))
    }
}


private actor WrongIDAgent: AgentAdapter {
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        let other = InteractionID()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(other, "cross-talk"))
            continuation.yield(.completed(other))
            continuation.finish()
        }
    }
}

extension InteractionCoordinatorTests {
    func testAgentCannotCrossTalkIntoAnotherInteractionID() async throws {
        let agent = WrongIDAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertFalse(events.contains { event in
            event.interactionID != nil && event.interactionID != id
        })
    }
}
