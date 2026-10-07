import XCTest
@testable import AgentWearLinkCore

private actor RecordedEvents {
    var values: [InteractionEvent] = []
    private let eventCount = TestCountSignal()

    func append(_ event: InteractionEvent) async {
        values.append(event)
        await eventCount.increment()
    }

    func waitUntilCount(_ count: Int) async throws {
        try await eventCount.wait(
            until: count,
            label: "interaction recorder event count \(count)"
        )
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


private actor SuspendedOutputRecorder {
    private var values: [InteractionEvent] = []
    private let textStarted = TestCountSignal()
    private var textGate: CheckedContinuation<Void, Never>?

    func append(_ event: InteractionEvent) async {
        if case .text = event {
            await textStarted.increment()
            await withCheckedContinuation { continuation in
                textGate = continuation
            }
        }
        values.append(event)
    }

    func waitUntilTextStarts() async throws {
        try await textStarted.wait(
            until: 1,
            label: "suspended output text emission"
        )
    }

    func releaseText() {
        textGate?.resume()
        textGate = nil
    }

    func recorded() -> [InteractionEvent] { values }
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
        let events = await recorded.values
        XCTAssertTrue(events.isEmpty)
    }

    func testOversizedTextIsRejectedBeforeAgentDispatch() async throws {
        let agent = StubAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(
            agent: agent,
            maximumRequestTextBytes: 8
        ) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "123456789"))
        try await recorded.waitUntilCount(1)

        let requestCount = await agent.requests()
        XCTAssertEqual(requestCount, 0)
        let events = await recorded.values
        XCTAssertEqual(
            events,
            [
                .failed(
                    id,
                    .overloaded("agent request text exceeds configured byte limit")
                )
            ]
        )
    }

    func testDuplicateRequestForInteractionIsSuppressed() async throws {
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let id = InteractionID()
        await coordinator.handle(.text(id, "hello"))
        try await agent.waitUntilRequestCount(1)
        await coordinator.handle(.text(id, "hello"))

        let requests = await agent.requests()
        XCTAssertEqual(requests, [id])
        await coordinator.cancelAll()
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


    func testCommittedTextCannotCrossLaterInterruptionBarrier() async throws {
        let agent = StubAgent()
        let recorded = SuspendedOutputRecorder()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await recorded.waitUntilTextStarts()

        let interruption = Task {
            await coordinator.handle(.interrupted(id))
        }

        await recorded.releaseText()
        await interruption.value

        let events = await recorded.recorded()
        XCTAssertEqual(
            events,
            [
                .text(id, "response"),
                .interrupted(id),
            ]
        )
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
        try await recorded.waitUntilCount(2)
        try await waitUntilTestCondition("first interaction task retired") {
            await coordinator.inFlightInteractionCount() == 0
        }

        await coordinator.handle(.text(id, "second"))
        try await recorded.waitUntilCount(4)

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
        try await recorded.waitUntilCount(2)

        let events = await recorded.values
        XCTAssertTrue(events.contains(.text(id, "response")))
    }
}


private actor DelayedFirstAgent: AgentAdapter {
    private(set) var requestCount = 0
    private let requestSignal = TestCountSignal()
    private var firstGate: CheckedContinuation<Void, Never>?
    private var continuations: [AsyncThrowingStream<AgentResponse, Error>.Continuation] = []

    func connect() async throws {}
    func disconnect() async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        requestCount += 1
        let ordinal = requestCount
        await requestSignal.increment()

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

    func waitUntilRequestCount(_ count: Int) async throws {
        try await requestSignal.wait(
            until: count,
            label: "delayed agent request count \(count)"
        )
    }

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
    private let responseStartSignal = TestCountSignal()
    private var continuation: AsyncThrowingStream<AgentResponse, Error>.Continuation?
    private(set) var cancelled: [InteractionID] = []

    func connect() async throws {}
    func disconnect() async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        await responseStartSignal.increment()
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

    func waitUntilResponseStarts() async throws {
        try await responseStartSignal.wait(
            until: 1,
            label: "pending agent response start"
        )
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
        try await agent.waitUntilRequestCount(1)

        await coordinator.handle(.interrupted(id))
        await coordinator.handle(.text(id, "second"))
        try await agent.waitUntilRequestCount(2)

        let afterReplacement = await agent.requests()
        XCTAssertEqual(afterReplacement, 2)

        await agent.releaseFirst()
        await coordinator.handle(.text(id, "third"))

        let finalCount = await agent.requests()
        XCTAssertEqual(finalCount, 2)

        await coordinator.cancelAll()
        await agent.finishAll()
    }


    func testAgentTurnCompletionAndLaterDeviceSessionEndRemainDistinct() async throws {
        let agent = StubAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.sessionStarted(id))
        await coordinator.handle(.text(id, "hello"))
        try await recorded.waitUntilCount(3)

        await coordinator.handle(.sessionEnded(id))
        try await recorded.waitUntilCount(4)

        let events = await recorded.values
        XCTAssertEqual(
            events,
            [
                .sessionStarted(id),
                .text(id, "response"),
                .turnCompleted(id),
                .sessionEnded(id),
            ]
        )
    }

    func testDeviceSessionEndCancelsTurnBeforeLateAgentCompletion() async throws {
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await agent.waitUntilRequestCount(1)

        await coordinator.handle(.sessionEnded(id))
        await agent.complete(id)

        let events = await recorded.values
        XCTAssertEqual(events, [.sessionEnded(id)])
    }

    func testDeviceFailureWinsOverLaterSessionEndAndRepeatedTerminalEvents() async throws {
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await agent.waitUntilRequestCount(1)

        await coordinator.handle(.failed(id, .device("link lost")))
        await coordinator.handle(.sessionEnded(id))
        await coordinator.handle(.sessionEnded(id))

        let events = await recorded.values
        XCTAssertEqual(events, [.failed(id, .device("link lost"))])
    }

    func testTerminalResponseStopsLateDeltas() async throws {
        let agent = TerminalThenLateAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }
        let id = InteractionID()

        await coordinator.handle(.text(id, "hello"))
        try await recorded.waitUntilCount(1)

        let events = await recorded.values
        XCTAssertTrue(events.contains(.turnCompleted(id)))
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
        try await recorded.waitUntilCount(1)

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
        try await recorded.waitUntilCount(1)

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
        try await recorded.waitUntilCount(2)

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
        try await recorded.waitUntilCount(1)

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
        try await agent.waitUntilResponseStarts()
        await coordinator.handle(.interrupted(id))

        let events = await recorded.values
        XCTAssertEqual(events, [.interrupted(id)])
        let cancellations = await agent.cancellations()
        XCTAssertEqual(cancellations, [id])
    }
}


private actor CapacityHoldingAgent: AgentAdapter {
    private var requestedIDs: [InteractionID] = []
    private var cancelledIDs: [InteractionID] = []
    private var continuations: [
        InteractionID: AsyncThrowingStream<AgentResponse, Error>.Continuation
    ] = [:]
    private let requestSignal = TestCountSignal()

    func connect() async throws {}
    func disconnect() async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        requestedIDs.append(request.interactionID)
        await requestSignal.increment()

        var captured: AsyncThrowingStream<AgentResponse, Error>.Continuation?
        let stream = AsyncThrowingStream<AgentResponse, Error> { continuation in
            captured = continuation
        }
        continuations[request.interactionID] = captured
        return stream
    }

    func cancel(interactionID: InteractionID) async {
        cancelledIDs.append(interactionID)
        continuations.removeValue(forKey: interactionID)?.finish()
    }

    func waitUntilRequestCount(_ count: Int) async throws {
        try await requestSignal.wait(
            until: count,
            label: "capacity agent request count \(count)"
        )
    }

    func requests() -> [InteractionID] { requestedIDs }
    func cancellations() -> [InteractionID] { cancelledIDs }

    func complete(_ id: InteractionID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.yield(.completed(id))
        continuation.finish()
    }
}

extension InteractionCoordinatorTests {
    func testCapacityRejectsNewestAndCancellationReleasesSlot() async throws {
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(
            agent: agent,
            maximumInFlightInteractions: 2
        ) { event in
            await recorded.append(event)
        }

        let first = InteractionID()
        let second = InteractionID()
        let rejected = InteractionID()
        let admittedAfterCancel = InteractionID()

        await coordinator.handle(.text(first, "first"))
        await coordinator.handle(.text(second, "second"))
        try await agent.waitUntilRequestCount(2)

        let fullCount = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(fullCount, 2)

        await coordinator.handle(.text(rejected, "third"))
        let eventsAfterReject = await recorded.values
        XCTAssertTrue(
            eventsAfterReject.contains(
                .failed(
                    rejected,
                    .overloaded("maximum in-flight interaction capacity reached")
                )
            )
        )

        await coordinator.cancel(first)
        let afterCancelCount = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(afterCancelCount, 1)

        await coordinator.handle(.text(admittedAfterCancel, "replacement"))
        try await agent.waitUntilRequestCount(3)

        let finalCount = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(finalCount, 2)

        let requests = await agent.requests()
        XCTAssertFalse(requests.contains(rejected))
        XCTAssertTrue(requests.contains(admittedAfterCancel))

        await coordinator.cancelAll()
        let afterCancelAll = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(afterCancelAll, 0)
    }

    func testBurstNeverReservesMoreThanConfiguredCapacity() async throws {
        let capacity = 4
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(
            agent: agent,
            maximumInFlightInteractions: capacity
        ) { event in
            await recorded.append(event)
        }

        let ids = (0..<100).map { _ in InteractionID() }
        for id in ids {
            await coordinator.handle(.text(id, "burst"))
        }

        let inFlight = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(inFlight, capacity)

        try await agent.waitUntilRequestCount(capacity)
        let requests = await agent.requests()
        XCTAssertEqual(requests.count, capacity)

        let events = await recorded.values
        let overloads = events.filter { event in
            guard case let .failed(_, error) = event else { return false }
            guard case .overloaded = error else { return false }
            return true
        }
        XCTAssertEqual(overloads.count, ids.count - capacity)

        await coordinator.cancelAll()
        let afterCancelAll = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(afterCancelAll, 0)
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
        try await recorded.waitUntilCount(1)

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


extension InteractionCoordinatorTests {
    func testGlobalDeviceFailureCancelsEveryInFlightInteractionExactlyOnce() async throws {
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let first = InteractionID()
        let second = InteractionID()

        await coordinator.handle(.text(first, "first"))
        await coordinator.handle(.text(second, "second"))
        try await agent.waitUntilRequestCount(2)

        await coordinator.handle(.failed(nil, .device("session lost")))
        try await recorded.waitUntilCount(1)

        let inFlight = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(inFlight, 0)

        let cancellations = await agent.cancellations()
        XCTAssertEqual(Set(cancellations), Set([first, second]))
        XCTAssertEqual(cancellations.count, 2)

        let events = await recorded.values
        XCTAssertEqual(events, [.failed(nil, .device("session lost"))])
    }

    func testGlobalNonDeviceDiagnosticDoesNotCancelInFlightInteraction() async throws {
        let agent = CapacityHoldingAgent()
        let recorded = RecordedEvents()
        let coordinator = InteractionCoordinator(agent: agent) { event in
            await recorded.append(event)
        }

        let id = InteractionID()
        await coordinator.handle(.text(id, "active"))
        try await agent.waitUntilRequestCount(1)

        await coordinator.handle(.failed(nil, .transport("diagnostic")))
        try await recorded.waitUntilCount(1)

        let inFlight = await coordinator.inFlightInteractionCount()
        XCTAssertEqual(inFlight, 1)
        let cancellations = await agent.cancellations()
        XCTAssertTrue(cancellations.isEmpty)

        await coordinator.cancelAll()
    }
}
