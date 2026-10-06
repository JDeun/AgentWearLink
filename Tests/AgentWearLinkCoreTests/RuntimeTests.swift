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
