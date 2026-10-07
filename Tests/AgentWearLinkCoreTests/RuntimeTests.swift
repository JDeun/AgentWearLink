import Foundation
import XCTest
@testable import AgentWearLinkCore

private actor RuntimeRecorder {
    var events: [InteractionEvent] = []
    private let eventCount = TestCountSignal()

    func append(_ event: InteractionEvent) async {
        events.append(event)
        await eventCount.increment()
    }

    func waitUntilCount(_ count: Int) async throws {
        try await eventCount.wait(
            until: count,
            label: "runtime recorder event count \(count)"
        )
    }
}

private actor RuntimeOutputSinkRecorder: InteractionOutputSink {
    private(set) var events: [InteractionEvent] = []
    private let eventCount = TestCountSignal()

    func consume(_ event: InteractionEvent) async {
        events.append(event)
        await eventCount.increment()
    }

    func waitUntilCount(_ count: Int) async throws {
        try await eventCount.wait(
            until: count,
            label: "runtime output sink event count \(count)"
        )
    }

    func snapshot() -> [InteractionEvent] { events }
}

private final class ConnectEmittingDevice: DeviceAdapter, @unchecked Sendable {
    let capabilities: CapabilitySet = [.textInput]
    private let stream: AsyncStream<InteractionEvent>
    private let continuation: AsyncStream<InteractionEvent>.Continuation
    let emittedID = InteractionID()

    init() {
        var captured: AsyncStream<InteractionEvent>.Continuation!
        self.stream = AsyncStream(
            bufferingPolicy: .bufferingOldest(1)
        ) { captured = $0 }
        self.continuation = captured
    }

    func connect() async throws {
        continuation.yield(.text(emittedID, "during-connect"))
    }

    func disconnect() async { continuation.finish() }
    func events() -> AsyncStream<InteractionEvent> { stream }
}

private final class ConnectEmittingFailingDevice: DeviceAdapter, @unchecked Sendable {
    let capabilities: CapabilitySet = [.textInput]
    private let stream: AsyncStream<InteractionEvent>
    private let continuation: AsyncStream<InteractionEvent>.Continuation
    let emittedID = InteractionID()

    init() {
        var captured: AsyncStream<InteractionEvent>.Continuation!
        self.stream = AsyncStream(
            bufferingPolicy: .bufferingOldest(1)
        ) { captured = $0 }
        self.continuation = captured
    }

    func connect() async throws {
        continuation.yield(.text(emittedID, "failed-generation"))
        throw AWLError.device("connect failed after event")
    }

    func disconnect() async {
        continuation.finish()
    }

    func events() -> AsyncStream<InteractionEvent> {
        stream
    }
}

private final class StartupTrackingDevice: DeviceAdapter, @unchecked Sendable {
    let capabilities: CapabilitySet = [.textInput]

    private let lock = NSLock()
    private var subscriptions = 0
    private var connects = 0
    private var disconnects = 0
    private var continuation: AsyncStream<InteractionEvent>.Continuation?

    func events() -> AsyncStream<InteractionEvent> {
        AsyncStream { continuation in
            let previous = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
                subscriptions += 1
                let previous = self.continuation
                self.continuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    func connect() async throws {
        lock.withLock {
            connects += 1
        }
    }

    func disconnect() async {
        let continuation = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
            disconnects += 1
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    func snapshot() -> (
        subscriptions: Int,
        connects: Int,
        disconnects: Int,
        hasActiveSubscription: Bool
    ) {
        lock.withLock {
            (
                subscriptions,
                connects,
                disconnects,
                continuation != nil
            )
        }
    }
}

private actor RuntimeHoldingAgent: AgentAdapter {
    private(set) var connects = 0
    private(set) var disconnects = 0
    private(set) var requested: [InteractionID] = []
    private(set) var cancelled: [InteractionID] = []
    private var continuations: [
        InteractionID: AsyncThrowingStream<AgentResponse, Error>.Continuation
    ] = [:]
    private let requestSignal = TestCountSignal()
    private let cancelSignal = TestCountSignal()

    func connect() async throws { connects += 1 }

    func disconnect() async {
        disconnects += 1
        let active = continuations.values
        continuations.removeAll(keepingCapacity: false)
        for continuation in active {
            continuation.finish()
        }
    }

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        requested.append(request.interactionID)
        await requestSignal.increment()

        let pair = AsyncThrowingStream<AgentResponse, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        continuations[request.interactionID] = pair.continuation
        return pair.stream
    }

    func cancel(interactionID: InteractionID) async {
        cancelled.append(interactionID)
        continuations.removeValue(forKey: interactionID)?.finish()
        await cancelSignal.increment()
    }

    func waitUntilRequestCount(_ count: Int) async throws {
        try await requestSignal.wait(
            until: count,
            label: "runtime holding agent request count \(count)"
        )
    }

    func waitUntilCancelCount(_ count: Int) async throws {
        try await cancelSignal.wait(
            until: count,
            label: "runtime holding agent cancel count \(count)"
        )
    }

    func snapshot() -> (
        connects: Int,
        disconnects: Int,
        requested: [InteractionID],
        cancelled: [InteractionID]
    ) {
        (connects, disconnects, requested, cancelled)
    }
}

private actor LifecycleAgent: AgentAdapter {
    private(set) var connects = 0
    private(set) var disconnects = 0
    private var remainingConnectFailures: Int

    init(failConnect: Bool = false) {
        self.remainingConnectFailures = failConnect ? 1 : 0
    }

    func connect() async throws {
        connects += 1
        if remainingConnectFailures > 0 {
            remainingConnectFailures -= 1
            throw AWLError.agent("connect failed")
        }
    }

    func disconnect() async { disconnects += 1 }

    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel(interactionID: InteractionID) async {}

    func counts() -> (Int, Int) { (connects, disconnects) }
}

private actor BlockingLifecycleAgent: AgentAdapter {
    private(set) var connects = 0
    private(set) var disconnects = 0

    private let connectSignal = TestCountSignal()
    private let disconnectSignal = TestCountSignal()

    private var released = false
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private let connectError: AWLError?

    private let blockDisconnect: Bool
    private var disconnectReleased: Bool
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        connectError: AWLError? = nil,
        blockDisconnect: Bool = false
    ) {
        self.connectError = connectError
        self.blockDisconnect = blockDisconnect
        self.disconnectReleased = !blockDisconnect
    }

    func connect() async throws {
        connects += 1
        await connectSignal.increment()

        if !released {
            await withCheckedContinuation { connectWaiters.append($0) }
        }
        if let connectError {
            throw connectError
        }
    }

    func disconnect() async {
        disconnects += 1
        await disconnectSignal.increment()

        if !disconnectReleased {
            await withCheckedContinuation { disconnectWaiters.append($0) }
        }
    }

    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel(interactionID: InteractionID) async {}

    func release() {
        released = true
        for waiter in connectWaiters { waiter.resume() }
        connectWaiters.removeAll()
    }

    func releaseDisconnect() {
        disconnectReleased = true
        for waiter in disconnectWaiters { waiter.resume() }
        disconnectWaiters.removeAll()
    }

    func waitUntilConnectCount(_ count: Int) async throws {
        try await connectSignal.wait(
            until: count,
            label: "lifecycle agent connect count \(count)"
        )
    }

    func waitUntilDisconnectCount(_ count: Int) async throws {
        try await disconnectSignal.wait(
            until: count,
            label: "lifecycle agent disconnect count \(count)"
        )
    }

    func connectCount() -> Int { connects }
    func counts() -> (Int, Int) { (connects, disconnects) }
}

private actor FailingDevice: DeviceAdapter {
    nonisolated let capabilities: CapabilitySet = []
    private(set) var disconnects = 0

    func connect() async throws {
        throw AWLError.device("connect failed")
    }

    func disconnect() async { disconnects += 1 }

    nonisolated func events() -> AsyncStream<InteractionEvent> {
        AsyncStream { _ in }
    }
}

private final class RestartableEndingDevice: DeviceAdapter, @unchecked Sendable {
    let capabilities: CapabilitySet = [.textInput]

    private let lock = NSLock()
    private var continuation: AsyncStream<InteractionEvent>.Continuation?
    private var subscriptions = 0
    private var connects = 0
    private var disconnects = 0

    func events() -> AsyncStream<InteractionEvent> {
        AsyncStream { continuation in
            let previous = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
                subscriptions += 1
                let previous = self.continuation
                self.continuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    func connect() async throws {
        lock.withLock { connects += 1 }
    }

    func disconnect() async {
        let active = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
            disconnects += 1
            let active = continuation
            continuation = nil
            return active
        }
        active?.finish()
    }

    func emit(_ event: InteractionEvent) {
        let active = lock.withLock { continuation }
        active?.yield(event)
    }

    func finishUnexpectedly() {
        let active = lock.withLock { () -> AsyncStream<InteractionEvent>.Continuation? in
            let active = continuation
            continuation = nil
            return active
        }
        active?.finish()
    }

    func snapshot() -> (
        subscriptions: Int,
        connects: Int,
        disconnects: Int,
        hasActiveSubscription: Bool
    ) {
        lock.withLock {
            (
                subscriptions,
                connects,
                disconnects,
                continuation != nil
            )
        }
    }
}

final class RuntimeTests: XCTestCase {
    func testTypedOutputSinkReceivesNormalizedAgentResponse() async throws {
        let device = MockDeviceAdapter()
        let agent = MockAgentAdapter()
        let sink = RuntimeOutputSinkRecorder()
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent,
            outputSink: sink
        )

        try await runtime.start()

        let id = InteractionID()
        await device.emit(.text(id, "hello"))
        try await sink.waitUntilCount(2)

        let events = await sink.snapshot()
        XCTAssertEqual(
            events,
            [
                .text(id, "echo: hello"),
                .turnCompleted(id)
            ]
        )

        await runtime.stop()
    }

    func testMockDeviceSubscriptionIsInstalledBeforeEventsReturns() async {
        let device = MockDeviceAdapter()
        var iterator = device.events().makeAsyncIterator()
        let id = InteractionID()
        let expected = InteractionEvent.text(id, "immediate")

        await device.emit(expected)

        let received = await iterator.next()
        XCTAssertEqual(received, expected)
        await device.disconnect()
    }

    func testReplacingMockSubscriptionDoesNotLetOldTerminationClearNewSubscriber() async {
        let device = MockDeviceAdapter()
        var first = device.events().makeAsyncIterator()
        var second = device.events().makeAsyncIterator()
        let id = InteractionID()
        let expected = InteractionEvent.text(id, "new-subscriber")

        let firstResult = await first.next()
        XCTAssertNil(firstResult)

        await device.emit(expected)

        let secondResult = await second.next()
        XCTAssertEqual(secondResult, expected)
        await device.disconnect()
    }

    func testMockDeviceToMockAgentRoundTrip() async throws {
        let device = MockDeviceAdapter()
        let agent = MockAgentAdapter()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent
        ) { event in
            await recorder.append(event)
        }

        try await runtime.start()

        let id = InteractionID()
        await device.emit(.text(id, "hello"))
        try await recorder.waitUntilCount(2)

        let events = await recorder.events
        XCTAssertTrue(events.contains(.text(id, "echo: hello")))
        XCTAssertTrue(events.contains(.turnCompleted(id)))

        await runtime.stop()
    }

    func testEventEmittedDuringDeviceConnectIsNotLost() async throws {
        let device = ConnectEmittingDevice()
        let agent = MockAgentAdapter()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent) { event in
            await recorder.append(event)
        }

        try await runtime.start()
        try await recorder.waitUntilCount(2)

        let events = await recorder.events
        XCTAssertTrue(events.contains(.text(device.emittedID, "echo: during-connect")))
        await runtime.stop()
    }

    func testFailedConnectDoesNotForwardRetainedStartupEvent() async {
        let device = ConnectEmittingFailingDevice()
        let agent = MockAgentAdapter()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent
        ) { event in
            await recorder.append(event)
        }

        do {
            try await runtime.start()
            XCTFail("Expected device connect failure")
        } catch {}

        // The bounded stream retained the connect-time event, but the runtime
        // never commits a failed startup generation to the coordinator.
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }

    func testAgentConnectFailureRollsBackPreSubscribedDeviceAndCanRestart() async throws {
        let device = StartupTrackingDevice()
        let agent = LifecycleAgent(failConnect: true)
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent,
            output: { _ in }
        )

        do {
            try await runtime.start()
            XCTFail("expected first start to fail")
        } catch let error as AWLError {
            XCTAssertEqual(error, .agent("connect failed"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let afterFailure = device.snapshot()
        XCTAssertEqual(afterFailure.subscriptions, 1)
        XCTAssertEqual(afterFailure.connects, 0)
        XCTAssertEqual(afterFailure.disconnects, 1)
        XCTAssertFalse(afterFailure.hasActiveSubscription)

        let agentAfterFailure = await agent.counts()
        XCTAssertEqual(agentAfterFailure.0, 1)
        XCTAssertEqual(agentAfterFailure.1, 1)

        try await runtime.start()
        await runtime.stop()

        let afterRestart = device.snapshot()
        XCTAssertEqual(afterRestart.subscriptions, 2)
        XCTAssertEqual(afterRestart.connects, 1)
        XCTAssertEqual(afterRestart.disconnects, 2)
        XCTAssertFalse(afterRestart.hasActiveSubscription)

        let agentAfterRestart = await agent.counts()
        XCTAssertEqual(agentAfterRestart.0, 2)
        XCTAssertEqual(agentAfterRestart.1, 2)
    }

    func testDeviceConnectFailureRollsBackAgentConnection() async {
        let device = FailingDevice()
        let agent = LifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        do {
            try await runtime.start()
            XCTFail("expected start failure")
        } catch {}

        let counts = await agent.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    func testRuntimeCanRestartAfterStop() async throws {
        let device = MockDeviceAdapter()
        let agent = LifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        try await runtime.start()
        await runtime.stop()
        try await runtime.start()
        await runtime.stop()

        let counts = await agent.counts()
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 2)
    }

    func testConcurrentStartOnlyConnectsOnce() async throws {
        let device = MockDeviceAdapter()
        let agent = BlockingLifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        let first = Task { try await runtime.start() }
        try await agent.waitUntilConnectCount(1)
        let second = Task { try await runtime.start() }
        try await waitUntilTestCondition("second start joined active startup") {
            await runtime.startWaiterCountForTesting() == 1
        }

        await agent.release()
        try await first.value
        try await second.value

        let connectCount = await agent.connectCount()
        XCTAssertEqual(connectCount, 1)
        await runtime.stop()
    }


    func testConcurrentStartJoinsTheSameFailureResult() async {
        let device = MockDeviceAdapter()
        let agent = BlockingLifecycleAgent(
            connectError: .agent("blocked failure")
        )
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent,
            output: { _ in }
        )

        let first = Task { try await runtime.start() }
        try? await agent.waitUntilConnectCount(1)

        let second = Task { try await runtime.start() }
        try? await waitUntilTestCondition("second start joined failing startup") {
            await runtime.startWaiterCountForTesting() == 1
        }
        await agent.release()

        for task in [first, second] {
            do {
                try await task.value
                XCTFail("expected joined startup failure")
            } catch let error as AWLError {
                XCTAssertEqual(error, .agent("blocked failure"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let connectCount = await agent.connectCount()
        XCTAssertEqual(connectCount, 1)
    }

    func testCancelledStartupCannotPublishRunningOrConnectDevice() async {
        let device = StartupTrackingDevice()
        let agent = BlockingLifecycleAgent()
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent,
            output: { _ in }
        )

        let starting = Task { try await runtime.start() }
        try? await agent.waitUntilConnectCount(1)

        starting.cancel()
        await agent.release()

        do {
            try await starting.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let snapshot = device.snapshot()
        XCTAssertEqual(snapshot.connects, 0)
        XCTAssertGreaterThanOrEqual(snapshot.disconnects, 1)

        // A fresh generation can still start after the cancelled startup
        // retired and rolled back.
        try? await runtime.start()
        await runtime.stop()
    }

    func testStopDuringStartCannotResurrectRuntime() async throws {
        let device = MockDeviceAdapter()
        let agent = BlockingLifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        let starting = Task { try await runtime.start() }
        try await agent.waitUntilConnectCount(1)
        let connectCount = await agent.connectCount()
        XCTAssertEqual(connectCount, 1)

        let stopping = Task { await runtime.stop() }
        try await waitUntilTestCondition(
            "runtime entered stopping during startup"
        ) {
            await runtime.isStoppingForTesting()
        }
        await agent.release()

        do {
            try await starting.value
            XCTFail("expected startup to be superseded by stop")
        } catch let error as AgentWearLinkRuntimeError {
            XCTAssertEqual(error, .startSuperseded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await stopping.value

        let afterInterruptedStart = await agent.counts()
        XCTAssertEqual(afterInterruptedStart.0, 1)
        XCTAssertGreaterThanOrEqual(afterInterruptedStart.1, 1)

        try await runtime.start()
        await runtime.stop()

        let final = await agent.counts()
        XCTAssertEqual(final.0, 2)
        XCTAssertGreaterThanOrEqual(final.1, 2)
    }

    func testFailedDeviceConnectAlsoRollsBackDevice() async {
        let device = FailingDevice()
        let agent = LifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        do {
            try await runtime.start()
            XCTFail("expected start failure")
        } catch {}

        let deviceDisconnects = await device.disconnects
        XCTAssertEqual(deviceDisconnects, 1)
    }

    func testStartDuringStopWaitsForTeardownThenRestarts() async throws {
        let device = MockDeviceAdapter()
        let agent = BlockingLifecycleAgent(blockDisconnect: true)
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        await agent.release()
        try await runtime.start()

        let stopping = Task { await runtime.stop() }
        try await agent.waitUntilDisconnectCount(1)

        // Hold teardown inside disconnect() so start() must observe .stopping
        // and register as a stop waiter before teardown is released.
        let restarting = Task { try await runtime.start() }
        try await waitUntilTestCondition("restart joined active stop") {
            await runtime.stopWaiterCountForTesting() == 1
        }
        await agent.releaseDisconnect()

        await stopping.value
        try await restarting.value
        await runtime.stop()

        let counts = await agent.counts()
        XCTAssertEqual(counts.0, 2)
        XCTAssertGreaterThanOrEqual(counts.1, 2)
    }

    func testStartIsIdempotent() async throws {
        let device = MockDeviceAdapter()
        let agent = MockAgentAdapter()
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent,
            output: { _ in }
        )

        try await runtime.start()
        try await runtime.start()
        await runtime.stop()
    }



    func testGlobalDeviceFailureCancelsAllInteractionsAndTearsDownRuntime() async throws {
        let device = RestartableEndingDevice()
        let agent = RuntimeHoldingAgent()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent) { event in
            await recorder.append(event)
        }

        try await runtime.start()

        let first = InteractionID()
        let second = InteractionID()
        device.emit(.text(first, "first"))
        device.emit(.text(second, "second"))
        try await agent.waitUntilRequestCount(2)

        device.emit(.failed(nil, .device("registration lost")))

        try await agent.waitUntilCancelCount(2)
        try await recorder.waitUntilCount(1)
        try await waitUntilTestCondition("global failure runtime teardown") {
            let state = await agent.snapshot()
            return state.disconnects == 1
        }

        let agentState = await agent.snapshot()
        XCTAssertEqual(agentState.connects, 1)
        XCTAssertEqual(agentState.disconnects, 1)
        XCTAssertEqual(Set(agentState.requested), Set([first, second]))
        XCTAssertEqual(agentState.cancelled.count, 2)
        XCTAssertEqual(Set(agentState.cancelled), Set([first, second]))

        let deviceState = device.snapshot()
        XCTAssertEqual(deviceState.disconnects, 1)
        XCTAssertFalse(deviceState.hasActiveSubscription)

        let events = await recorder.events
        XCTAssertEqual(events, [.failed(nil, .device("registration lost"))])

        // A terminal global failure retires only the failed generation; the
        // runtime remains restartable after teardown completes.
        try await runtime.start()
        await runtime.stop()

        let restartedAgentState = await agent.snapshot()
        XCTAssertEqual(restartedAgentState.connects, 2)
        XCTAssertEqual(restartedAgentState.disconnects, 2)
        XCTAssertEqual(restartedAgentState.cancelled.count, 2)
    }

    func testUnexpectedDeviceEventStreamFinishFailsAndCleansUpRuntime() async throws {
        let device = RestartableEndingDevice()
        let agent = LifecycleAgent()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent) { event in
            await recorder.append(event)
        }

        try await runtime.start()
        device.finishUnexpectedly()
        try await recorder.waitUntilCount(1)

        let events = await recorder.events
        XCTAssertEqual(
            events,
            [.failed(nil, .device("device event stream ended unexpectedly"))]
        )

        let deviceState = device.snapshot()
        XCTAssertEqual(deviceState.subscriptions, 1)
        XCTAssertEqual(deviceState.connects, 1)
        XCTAssertEqual(deviceState.disconnects, 1)
        XCTAssertFalse(deviceState.hasActiveSubscription)

        let agentState = await agent.counts()
        XCTAssertEqual(agentState.0, 1)
        XCTAssertEqual(agentState.1, 1)
    }

    func testIntentionalStopDoesNotReportDeviceStreamFailure() async throws {
        let device = RestartableEndingDevice()
        let agent = LifecycleAgent()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent) { event in
            await recorder.append(event)
        }

        try await runtime.start()
        await runtime.stop()

        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)

        let deviceState = device.snapshot()
        XCTAssertEqual(deviceState.disconnects, 1)
        XCTAssertFalse(deviceState.hasActiveSubscription)
    }

    func testRuntimeCanRestartAfterUnexpectedDeviceStreamFailure() async throws {
        let device = RestartableEndingDevice()
        let agent = LifecycleAgent()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent) { event in
            await recorder.append(event)
        }

        try await runtime.start()
        device.finishUnexpectedly()
        try await recorder.waitUntilCount(1)

        try await runtime.start()
        await runtime.stop()

        let deviceState = device.snapshot()
        XCTAssertEqual(deviceState.subscriptions, 2)
        XCTAssertEqual(deviceState.connects, 2)
        XCTAssertEqual(deviceState.disconnects, 2)
        XCTAssertFalse(deviceState.hasActiveSubscription)

        let agentState = await agent.counts()
        XCTAssertEqual(agentState.0, 2)
        XCTAssertEqual(agentState.1, 2)

        let events = await recorder.events
        XCTAssertEqual(
            events,
            [.failed(nil, .device("device event stream ended unexpectedly"))]
        )
    }
}
