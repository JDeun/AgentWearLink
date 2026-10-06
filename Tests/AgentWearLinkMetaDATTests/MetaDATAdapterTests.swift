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
