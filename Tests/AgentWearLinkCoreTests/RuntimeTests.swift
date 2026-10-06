import Foundation
import XCTest
@testable import AgentWearLinkCore

private actor RuntimeRecorder {
    var events: [InteractionEvent] = []
    func append(_ event: InteractionEvent) { events.append(event) }
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
            lock.lock()
            subscriptions += 1
            let previous = self.continuation
            self.continuation = continuation
            lock.unlock()
            previous?.finish()
        }
    }

    func connect() async throws {
        lock.lock()
        connects += 1
        lock.unlock()
    }

    func disconnect() async {
        lock.lock()
        disconnects += 1
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    func snapshot() -> (
        subscriptions: Int,
        connects: Int,
        disconnects: Int,
        hasActiveSubscription: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            subscriptions,
            connects,
            disconnects,
            continuation != nil
        )
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

    func connect() async throws {
        connects += 1
        if !released {
            await withCheckedContinuation { waiters.append($0) }
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

final class RuntimeTests: XCTestCase {
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
        try await Task.sleep(for: .milliseconds(10))

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

    func testStopDuringStartCannotResurrectRuntime() async throws {
        let device = MockDeviceAdapter()
        let agent = BlockingLifecycleAgent()
        let runtime = AgentWearLinkRuntime(device: device, agent: agent, output: { _ in })

        let starting = Task { try await runtime.start() }
        try await Task.sleep(for: .milliseconds(10))
        let connectCount = await agent.connectCount()
        XCTAssertEqual(connectCount, 1)

        await runtime.stop()
        await agent.release()
        try await starting.value

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
}
