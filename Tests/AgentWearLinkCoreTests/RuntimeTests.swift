import Foundation
import XCTest
@testable import AgentWearLinkCore

private actor RuntimeRecorder {
    var events: [InteractionEvent] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ event: InteractionEvent) {
        events.append(event)

        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if events.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        countWaiters = pending
    }

    func waitUntilCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}

private final class ConnectEmittingDevice: DeviceAdapter, @unchecked Sendable {
    let capabilities: CapabilitySet = [.textInput]
    private let stream: AsyncStream<InteractionEvent>
    private let continuation: AsyncStream<InteractionEvent>.Continuation
    let emittedID = InteractionID()

    init() {
        var captured: AsyncStream<InteractionEvent>.Continuation!
        self.stream = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func connect() async throws {
        continuation.yield(.text(emittedID, "during-connect"))
    }

    func disconnect() async { continuation.finish() }
    func events() -> AsyncStream<InteractionEvent> { stream }
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
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let connectError: AWLError?

    init(connectError: AWLError? = nil) {
        self.connectError = connectError
    }

    func connect() async throws {
        connects += 1
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        if let connectError {
            throw connectError
        }
    }

    private(set) var disconnects = 0

    func disconnect() async { disconnects += 1 }

    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancel(interactionID: InteractionID) async {}

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
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
        try await Task.sleep(for: .milliseconds(30))

        let events = await recorder.events
        XCTAssertTrue(events.contains(.text(id, "echo: hello")))
        XCTAssertTrue(events.contains(.sessionEnded(id)))

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
        try await Task.sleep(for: .milliseconds(30))

        let events = await recorder.events
        XCTAssertTrue(events.contains(.text(device.emittedID, "echo: during-connect")))
        await runtime.stop()
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
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { try await runtime.start() }
        try? await Task.sleep(for: .milliseconds(10))

        let connectCount = await agent.connectCount()
        XCTAssertEqual(connectCount, 1)
        await agent.release()
        try await first.value
        try await second.value
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
        while await agent.connectCount() == 0 {
            await Task.yield()
        }

        let second = Task { try await runtime.start() }
        await Task.yield()
        XCTAssertEqual(await agent.connectCount(), 1)

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
        while await agent.connectCount() == 0 {
            await Task.yield()
        }

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
        try await Task.sleep(for: .milliseconds(10))
        let connectCount = await agent.connectCount()
        XCTAssertEqual(connectCount, 1)

        let stopping = Task { await runtime.stop() }
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
        let agent = BlockingLifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        await agent.release()
        try await runtime.start()

        let stopping = Task { await runtime.stop() }

        // Do not assume sibling Task scheduling order. Wait until stop() has
        // actually entered teardown before exercising start-during-stop.
        for _ in 0..<100 {
            let counts = await agent.counts()
            if counts.1 >= 1 { break }
            await Task.yield()
        }
        let enteredTeardown = await agent.counts()
        XCTAssertGreaterThanOrEqual(enteredTeardown.1, 1)

        let restarting = Task { try await runtime.start() }

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


    func testUnexpectedDeviceEventStreamFinishFailsAndCleansUpRuntime() async throws {
        let device = RestartableEndingDevice()
        let agent = LifecycleAgent()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent) { event in
            await recorder.append(event)
        }

        try await runtime.start()
        device.finishUnexpectedly()
        await recorder.waitUntilCount(1)

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
        await recorder.waitUntilCount(1)

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
