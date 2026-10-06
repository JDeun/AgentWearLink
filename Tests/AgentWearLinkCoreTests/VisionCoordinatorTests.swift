import XCTest
@testable import AgentWearLinkCore

private actor VisionStubDevice: SnapshotCapturingDevice {
    nonisolated let capabilities: CapabilitySet
    private(set) var captureCount = 0

    init(capabilities: CapabilitySet) { self.capabilities = capabilities }
    func connect() async throws {}
    func disconnect() async {}
    nonisolated func events() -> AsyncStream<InteractionEvent> { AsyncStream { $0.finish() } }

    func captureSnapshot(interactionID: InteractionID) async throws -> ImageAttachment {
        captureCount += 1
        return try ImageAttachment(data: Data([1]), format: .jpeg)
    }

    func captures() -> Int { captureCount }
}

private actor EmptyVisionStubDevice: SnapshotCapturingDevice {
    nonisolated let capabilities: CapabilitySet = [.cameraSnapshot]
    private(set) var captureCount = 0

    func connect() async throws {}
    func disconnect() async {}
    nonisolated func events() -> AsyncStream<InteractionEvent> { AsyncStream { $0.finish() } }

    func captureSnapshot(interactionID: InteractionID) async throws -> ImageAttachment {
        captureCount += 1
        return try ImageAttachment(data: Data(), format: .jpeg)
    }

    func captures() -> Int { captureCount }
}

private actor CancellationIgnoringVisionStubDevice: SnapshotCapturingDevice {
    nonisolated let capabilities: CapabilitySet = [.cameraSnapshot]

    private var captureStarted = false
    private var continuation: CheckedContinuation<ImageAttachment, Never>?

    func connect() async throws {}
    func disconnect() async {}
    nonisolated func events() -> AsyncStream<InteractionEvent> { AsyncStream { $0.finish() } }

    func captureSnapshot(interactionID: InteractionID) async throws -> ImageAttachment {
        captureStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilCaptureStarts() async {
        while !captureStarted {
            await Task.yield()
        }
    }

    func completeCapture() throws {
        let image = try ImageAttachment(data: Data([1, 2, 3]), format: .jpeg)
        continuation?.resume(returning: image)
        continuation = nil
    }
}

private actor VisionStubAgent: VisionAgentAdapter {
    nonisolated let supportsVisionInput: Bool
    private(set) var requestCount = 0

    init(supportsVisionInput: Bool = true) {
        self.supportsVisionInput = supportsVisionInput
    }
    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}
    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func responses(for request: VisionRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(request.interactionID))
            continuation.finish()
        }
    }
    func requests() -> Int { requestCount }
}

final class VisionCoordinatorTests: XCTestCase {
    func testUnsupportedCameraFailsBeforeCaptureOrAgentRequest() async {
        let device = VisionStubDevice(capabilities: [])
        let agent = VisionStubAgent()
        let coordinator = VisionCoordinator(device: device, agent: agent)

        do {
            _ = try await coordinator.responses(interactionID: InteractionID(), prompt: "what is this?")
            XCTFail("expected capability failure")
        } catch {
            XCTAssertEqual(error as? AWLError, .capabilityUnavailable("device does not support camera snapshots"))
        }

        let captures = await device.captures()
        let requests = await agent.requests()
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(requests, 0)
    }

    func testUnsupportedAgentFailsBeforePrivateMediaCapture() async {
        let device = VisionStubDevice(capabilities: [.cameraSnapshot])
        let agent = VisionStubAgent(supportsVisionInput: false)
        let coordinator = VisionCoordinator(device: device, agent: agent)

        do {
            _ = try await coordinator.responses(interactionID: InteractionID(), prompt: "what is this?")
            XCTFail("expected capability failure")
        } catch {
            XCTAssertEqual(error as? AWLError, .capabilityUnavailable("agent does not support image input"))
        }

        let captures = await device.captures()
        let requests = await agent.requests()
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(requests, 0)
    }

    func testEmptyCapturedImageFailsBeforeAgentRequest() async {
        let device = EmptyVisionStubDevice()
        let agent = VisionStubAgent()
        let coordinator = VisionCoordinator(device: device, agent: agent)

        do {
            _ = try await coordinator.responses(interactionID: InteractionID(), prompt: "what is this?")
            XCTFail("expected empty-image failure")
        } catch {
            XCTAssertEqual(error as? AWLError, .capabilityUnavailable("image payload is empty"))
        }

        let captures = await device.captures()
        let requests = await agent.requests()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(requests, 0)
    }


    func testCancellationAfterCaptureStartsPreventsPrivateMediaHandoff() async throws {
        let device = CancellationIgnoringVisionStubDevice()
        let agent = VisionStubAgent()
        let coordinator = VisionCoordinator(device: device, agent: agent)

        let task = Task {
            try await coordinator.responses(
                interactionID: InteractionID(),
                prompt: "what is this?"
            )
        }

        await device.waitUntilCaptureStarts()
        task.cancel()
        try await device.completeCapture()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: Core owns the privacy boundary even when capture ignores cancellation.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let requests = await agent.requests()
        XCTAssertEqual(requests, 0)
    }

    func testExplicitRequestCapturesExactlyOnce() async throws {
        let device = VisionStubDevice(capabilities: [.cameraSnapshot])
        let agent = VisionStubAgent()
        let coordinator = VisionCoordinator(device: device, agent: agent)

        _ = try await coordinator.responses(interactionID: InteractionID(), prompt: "what is this?")

        let captures = await device.captures()
        let requests = await agent.requests()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(requests, 1)
    }
}
