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
            continuation.yield(.completed(request.interactionID))
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
    func testRuntimeGenerationAdmissionRejectsStaleEventsAfterDeactivation() async {
        let agent = MockAgentAdapter()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in await recorded.append(event) }
        let generation: UInt64 = 41
        let id = InteractionID()
        await coordinator.activate(runtimeGeneration: generation)
        await coordinator.deactivate(runtimeGeneration: generation)
        await coordinator.handle(.text(id, "stale"), runtimeGeneration: generation)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue((await recorded.values).isEmpty)
    }

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

    func testInactiveTerminalEventDoesNotAbortAgent() async {
        let agent = StubAgent()
        let coordinator = InteractionCoordinator(agent: agent) { _ in }
        let id = InteractionID()

        await coordinator.handle(.sessionEnded(id))
        await coordinator.handle(.interrupted(id))

        let cancellations = await agent.cancellations()
        XCTAssertTrue(cancellations.isEmpty)
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

private actor EmptyStreamAgent: AgentAdapter {
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor DeltaThenEOFStreamAgent: AgentAdapter {
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(request.interactionID, "partial"))
            continuation.finish()
        }
    }
}

private actor ExplicitFailureResponseAgent: AgentAdapter {
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .failed(request.interactionID, .agent("explicit failure"))
            )
            continuation.finish()
        }
    }
}

private actor PendingUntilCancelledAgent: AgentAdapter {
    private var responseStarted = false
    private var continuation: AsyncThrowingStream<AgentResponse, Error>.Continuation?
    private(set) var cancelled: [InteractionID] = []

    func connect() async throws {}
    func disconnect() async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        responseStarted = true
        var captured: AsyncThrowingStream<AgentResponse, Error>.Continuation?
        let stream = AsyncThrowingStream<AgentResponse, Error> { continuation in
            captured = continuation
        }
        continuation = captured
        return stream
    }

    func cancel(interactionID: InteractionID) async {
        cancelled.append(interactionID)
        continuation?.finish()
        continuation = nil
    }

    func waitUntilResponseStarts() async {
        while !responseStarted {
            await Task.yield()
        }
    }

    func cancellations() -> [InteractionID] { cancelled }
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
        XCTAssertFalse(
            events.contains(
                .failed(id, .agent("response stream ended without terminal response"))
            )
        )
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


    func testEmptyAgentStreamFailsInsteadOfSilentlyEnding() async throws {
        let agent = EmptyStreamAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertEqual(
            events,
            [.failed(id, .agent("response stream ended without terminal response"))]
        )
    }

    func testDeltaThenEOFFailsExactlyOnceAfterPreservingDelta() async throws {
        let agent = DeltaThenEOFStreamAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertEqual(
            events,
            [
                .text(id, "partial"),
                .failed(id, .agent("response stream ended without terminal response")),
            ]
        )
    }

    func testExplicitFailureResponseDoesNotAlsoEmitEOFFailure() async throws {
        let agent = ExplicitFailureResponseAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertEqual(events, [.failed(id, .agent("explicit failure"))])
    }

    func testCancellationDrivenTerminationDoesNotEmitEOFFailure() async throws {
        let agent = PendingUntilCancelledAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        await agent.waitUntilResponseStarts()
        await coordinator.handle(.interrupted(id))
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorded.values
        XCTAssertEqual(events, [.interrupted(id)])
        let cancellations = await agent.cancellations()
        XCTAssertEqual(cancellations, [id])
    }
}


private actor WrongIDAgent: AgentAdapter {
    private var cancelled: [InteractionID] = []
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async { cancelled.append(interactionID) }
    func cancellations() -> [InteractionID] { cancelled }

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
        XCTAssertTrue(events.contains(.failed(id, .agent("response interaction ID mismatch"))))
        XCTAssertFalse(
            events.contains(
                .failed(id, .agent("response stream ended without terminal response"))
            )
        )
        let failures = events.filter { event in
            if case .failed = event { return true }
            return false
        }
        XCTAssertEqual(failures.count, 1)
        let cancellations = await agent.cancellations()
        XCTAssertEqual(cancellations, [id])
    }
}
