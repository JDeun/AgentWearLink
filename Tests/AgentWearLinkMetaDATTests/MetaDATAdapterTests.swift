import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkMetaDAT

final class MetaDATAdapterTests: XCTestCase {
    func testMapsOnlyAdvertisedCapabilities() async {
        let session = StubSession(
            capabilities: [.speech, .cameraSnapshot, .voiceInvocation]
        )
        let adapter = MetaDATAdapter(session: session)

        XCTAssertEqual(
            adapter.capabilities,
            [.speechInput, .cameraSnapshot, .voiceInvocation]
        )
        XCTAssertFalse(adapter.capabilities.contains(.rawAudioInput))
        XCTAssertFalse(adapter.capabilities.contains(.speakerOutput))
    }

    func testCapturesBoundedSnapshotThroughOptionalSession() async throws {
        let session = SnapshotStubSession(
            capabilities: [.cameraSnapshot],
            snapshot: MetaDATSnapshot(data: Data([1, 2, 3]), format: .jpeg)
        )
        let adapter = MetaDATAdapter(session: session)

        let image = try await adapter.captureSnapshot(
            interactionID: InteractionID(rawValue: UUID())
        )

        XCTAssertEqual(image.data, Data([1, 2, 3]))
        XCTAssertEqual(image.format, .jpeg)
        let captureCount = await session.captureCount
        XCTAssertEqual(captureCount, 1)
    }

    func testRejectsSnapshotWhenCapabilityNotAdvertised() async {
        let session = SnapshotStubSession(
            capabilities: [],
            snapshot: MetaDATSnapshot(data: Data([1]), format: .jpeg)
        )
        let adapter = MetaDATAdapter(session: session)

        do {
            _ = try await adapter.captureSnapshot(
                interactionID: InteractionID(rawValue: UUID())
            )
            XCTFail("Expected capability failure")
        } catch {
            guard case AWLError.capabilityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let captureCount = await session.captureCount
        XCTAssertEqual(captureCount, 0)
    }

    func testRejectsSnapshotWhenBridgeIsMissing() async {
        let adapter = MetaDATAdapter(
            session: StubSession(capabilities: [.cameraSnapshot])
        )

        do {
            _ = try await adapter.captureSnapshot(
                interactionID: InteractionID(rawValue: UUID())
            )
            XCTFail("Expected bridge failure")
        } catch {
            guard case AWLError.capabilityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsOversizedSnapshot() async {
        let session = SnapshotStubSession(
            capabilities: [.cameraSnapshot],
            snapshot: MetaDATSnapshot(
                data: Data(count: ImageAttachment.defaultMaximumBytes + 1),
                format: .jpeg
            )
        )
        let adapter = MetaDATAdapter(session: session)

        do {
            _ = try await adapter.captureSnapshot(
                interactionID: InteractionID(rawValue: UUID())
            )
            XCTFail("Expected bounded image failure")
        } catch {
            guard case AWLError.capabilityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNormalizesSessionEvents() async throws {
        let session = StubSession(capabilities: [.speech])
        let adapter = MetaDATAdapter(session: session)
        let stream = adapter.events()
        try await adapter.connect()

        let id = UUID()
        await session.emit(.sessionStarted(id))
        await session.emit(.transcript(id, "hello"))
        await session.emit(.sessionEnded(id))

        var iterator = stream.makeAsyncIterator()
        let started = await iterator.next()
        let text = await iterator.next()
        let ended = await iterator.next()

        XCTAssertEqual(started, .sessionStarted(InteractionID(rawValue: id)))
        XCTAssertEqual(text, .text(InteractionID(rawValue: id), "hello"))
        XCTAssertEqual(ended, .sessionEnded(InteractionID(rawValue: id)))

        await adapter.disconnect()
    }
}

private actor StubSession: MetaDATSession {
    nonisolated let capabilities: MetaDATCapabilities
    nonisolated private let stream: AsyncStream<MetaDATEvent>
    private let continuation: AsyncStream<MetaDATEvent>.Continuation

    init(capabilities: MetaDATCapabilities) {
        self.capabilities = capabilities
        let pair = AsyncStream<MetaDATEvent>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    nonisolated func events() -> AsyncStream<MetaDATEvent> {
        stream
    }

    func emit(_ event: MetaDATEvent) {
        continuation.yield(event)
    }
}


private actor SnapshotStubSession: MetaDATSnapshotSession {
    nonisolated let capabilities: MetaDATCapabilities
    nonisolated private let stream: AsyncStream<MetaDATEvent>
    private let continuation: AsyncStream<MetaDATEvent>.Continuation
    private let snapshot: MetaDATSnapshot
    private(set) var captureCount = 0

    init(capabilities: MetaDATCapabilities, snapshot: MetaDATSnapshot) {
        self.capabilities = capabilities
        self.snapshot = snapshot
        let pair = AsyncStream<MetaDATEvent>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    nonisolated func events() -> AsyncStream<MetaDATEvent> {
        stream
    }

    func captureSnapshotData() async throws -> MetaDATSnapshot {
        captureCount += 1
        return snapshot
    }
}
