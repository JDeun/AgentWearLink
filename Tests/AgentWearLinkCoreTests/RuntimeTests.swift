import XCTest
@testable import AgentWearLinkCore

private actor RuntimeRecorder {
    var events: [InteractionEvent] = []
    func append(_ event: InteractionEvent) { events.append(event) }
}

private actor ConnectEmittingDevice: DeviceAdapter {
    nonisolated let capabilities: CapabilitySet = []
    nonisolated private let stream: AsyncStream<InteractionEvent>
    private let continuation: AsyncStream<InteractionEvent>.Continuation
    private let connectEvent: InteractionEvent

    init(connectEvent: InteractionEvent) {
        self.connectEvent = connectEvent
        let pair = AsyncStream<InteractionEvent>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func connect() async throws {
        continuation.yield(connectEvent)
    }

    func disconnect() async {
        continuation.finish()
    }

    nonisolated func events() -> AsyncStream<InteractionEvent> {
        stream
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

    func testCapturesEventEmittedDuringDeviceConnect() async throws {
        let id = InteractionID()
        let device = ConnectEmittingDevice(
            connectEvent: .sessionStarted(id)
        )
        let agent = MockAgentAdapter()
        let recorder = RuntimeRecorder()
        let runtime = AgentWearLinkRuntime(
            device: device,
            agent: agent
        ) { event in
            await recorder.append(event)
        }

        try await runtime.start()
        try await Task.sleep(for: .milliseconds(20))

        let events = await recorder.events
        XCTAssertTrue(events.contains(.sessionStarted(id)))

        await runtime.stop()
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
