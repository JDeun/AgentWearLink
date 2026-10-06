import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkMetaDAT

final class MetaDATAdapterTests: XCTestCase {
    func testMapsOnlyAdvertisedCapabilities() async {
        let session = StubSession(capabilities: [.speech, .cameraSnapshot, .voiceInvocation])
        let adapter = MetaDATAdapter(session: session)
        XCTAssertEqual(adapter.capabilities, [.speechInput, .cameraSnapshot, .voiceInvocation])
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
        let transcript = await iterator.next()
        let ended = await iterator.next()
        XCTAssertEqual(started, .sessionStarted(InteractionID(rawValue: id)))
        XCTAssertEqual(transcript, .text(InteractionID(rawValue: id), "hello"))
        XCTAssertEqual(ended, .sessionEnded(InteractionID(rawValue: id)))
        await adapter.disconnect()
    }
}

private actor StubSession: MetaDATSession {
    nonisolated let capabilities: MetaDATCapabilities
    private var continuation: AsyncStream<MetaDATEvent>.Continuation?

    init(capabilities: MetaDATCapabilities) { self.capabilities = capabilities }
    func connect() async throws {}
    func disconnect() async { continuation?.finish(); continuation = nil }
    nonisolated func events() -> AsyncStream<MetaDATEvent> {
        AsyncStream { continuation in Task { await self.install(continuation) } }
    }
    private func install(_ continuation: AsyncStream<MetaDATEvent>.Continuation) { self.continuation = continuation }
    func emit(_ event: MetaDATEvent) { continuation?.yield(event) }
}
