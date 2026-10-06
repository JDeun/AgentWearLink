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

    func testDoesNotLoseEventEmittedDuringConnect() async throws {
        let id = UUID()
        let session = ConnectEmittingSession(
            event: .sessionStarted(id)
        )
        let adapter = MetaDATAdapter(session: session)
        let stream = adapter.events()
        var iterator = stream.makeAsyncIterator()

        try await adapter.connect()

        let event = await iterator.next()
        XCTAssertEqual(event, .sessionStarted(InteractionID(rawValue: id)))
        await adapter.disconnect()
    }

    func testRollsBackSessionWhenConnectFails() async {
        let session = FailingConnectSession()
        let adapter = MetaDATAdapter(session: session)

        do {
            try await adapter.connect()
            XCTFail("Expected connect failure")
        } catch {}

        XCTAssertEqual(await session.disconnectCount, 1)
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


private actor ConnectEmittingSession: MetaDATSession {
    nonisolated let capabilities: MetaDATCapabilities = []
    nonisolated private let stream: AsyncStream<MetaDATEvent>
    private let continuation: AsyncStream<MetaDATEvent>.Continuation
    private let event: MetaDATEvent

    init(event: MetaDATEvent) {
        self.event = event
        let pair = AsyncStream<MetaDATEvent>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func connect() async throws {
        continuation.yield(event)
    }

    func disconnect() async {
        continuation.finish()
    }

    nonisolated func events() -> AsyncStream<MetaDATEvent> {
        stream
    }
}

private actor FailingConnectSession: MetaDATSession {
    nonisolated let capabilities: MetaDATCapabilities = []
    private(set) var disconnectCount = 0

    func connect() async throws {
        throw AWLError.device("connect failed")
    }

    func disconnect() async {
        disconnectCount += 1
    }

    nonisolated func events() -> AsyncStream<MetaDATEvent> {
        AsyncStream { _ in }
    }
}
