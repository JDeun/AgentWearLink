import Foundation
import XCTest
@testable import AgentWearLinkCore

private final class ConnectionOrderRecordingDevice: DeviceAdapter, @unchecked Sendable {
    let capabilities: CapabilitySet = []
    private let lock = NSLock()
    private var count = 0
    private let stream: AsyncStream<InteractionEvent>
    private let continuation: AsyncStream<InteractionEvent>.Continuation

    init() {
        let pair = AsyncStream<InteractionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() -> AsyncStream<InteractionEvent> { stream }
    func connect() async throws { lock.withLock { count += 1 } }
    func disconnect() async { continuation.finish() }
    func connects() -> Int { lock.withLock { count } }
}

private actor ConnectionOrderDelayedAgent: AgentAdapter {
    private let entered = TestCountSignal()
    private var gate: CheckedContinuation<Void, Never>?

    func connect() async throws {
        await withCheckedContinuation { continuation in
            gate = continuation
            // Publish the arrival only after the release continuation is
            // installed, so an immediately waking test cannot miss it.
            Task { await entered.increment() }
        }
    }

    func waitUntilConnecting() async throws {
        try await entered.wait(until: 1, label: "Gateway start gate")
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func disconnect() async { release() }
    func cancel(interactionID: InteractionID) async {}

    func responses(
        for request: AgentRequest
    ) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class RuntimeConnectionOrderTests: XCTestCase {
    func testDeviceFirstStartsIndependentListenerBeforeGatewayHandshakeFinishes() async throws {
        let device = ConnectionOrderRecordingDevice()
        let agent = ConnectionOrderDelayedAgent()
        let runtime = AgentWearLinkRuntime(
            device: device, agent: agent, connectionOrder: .deviceFirst,
            output: { _ in }
        )

        let starting = Task { try await runtime.start() }
        try await agent.waitUntilConnecting()
        // The Gateway is still blocked, but the device listener is already
        // connected. The runtime subscribed to its buffered event stream first.
        XCTAssertEqual(device.connects(), 1)
        await agent.release()
        try await starting.value
        await runtime.stop()
    }

    func testExistingDefaultRemainsAgentFirst() async throws {
        let device = ConnectionOrderRecordingDevice()
        let agent = ConnectionOrderDelayedAgent()
        let runtime = AgentWearLinkRuntime(
            device: device, agent: agent, output: { _ in }
        )

        let starting = Task { try await runtime.start() }
        try await agent.waitUntilConnecting()
        XCTAssertEqual(device.connects(), 0)
        await agent.release()
        try await starting.value
        XCTAssertEqual(device.connects(), 1)
        await runtime.stop()
    }
}
