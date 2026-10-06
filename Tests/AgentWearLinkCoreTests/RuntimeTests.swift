import XCTest
@testable import AgentWearLinkCore

private actor RuntimeRecorder {
    var events: [InteractionEvent] = []
    func append(_ event: InteractionEvent) { events.append(event) }
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
