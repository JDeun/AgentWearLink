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

    func testDoesNotLoseEventEmittedDuringConnect() async throws {
        let id = UUID()
        let session = ConnectEmittingSession(event: .sessionStarted(id))
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

        let disconnectCount = await session.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testRejectsAdvertisedVoiceInvocationWithoutSource() async {
        let adapter = MetaDATAdapter(
            session: StubSession(capabilities: [.voiceInvocation])
        )

        do {
            try await adapter.connect()
            XCTFail("Expected missing invocation source failure")
        } catch {
            guard case AWLError.capabilityUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testForwardsIndependentVoiceInvocationSource() async throws {
        let id = UUID()
        let session = VoiceStubSession(
            invocation: MetaDATInvocation(id: id, phrase: "launch")
        )
        let adapter = MetaDATAdapter(session: session)
        let events = adapter.events()
        var iterator = events.makeAsyncIterator()

        try await adapter.connect()
        await session.emitInvocation()

        let event = await iterator.next()
        XCTAssertEqual(
            event,
            .invocation(InteractionID(rawValue: id), "launch")
        )
        await adapter.disconnect()
    }

    func testRejectsConcurrentSnapshotCapture() async throws {
        let session = BlockingSnapshotSession()
        let adapter = MetaDATAdapter(session: session)

        let first = Task {
            try await adapter.captureSnapshot(
                interactionID: InteractionID(rawValue: UUID())
            )
        }
        await session.waitUntilCaptureStarted()

        do {
            _ = try await adapter.captureSnapshot(
                interactionID: InteractionID(rawValue: UUID())
            )
            XCTFail("Expected concurrent capture rejection")
        } catch {
            guard case AWLError.device = error else {
                await session.release()
                _ = try? await first.value
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await session.release()
        _ = try await first.value
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



    func testGlobalSessionFailurePreservesNilInteractionIdentity() async throws {
        let session = RestartableMetaSession()
        let adapter = MetaDATAdapter(session: session)
        let stream = adapter.events()
        var iterator = stream.makeAsyncIterator()

        try await adapter.connect()
        session.emit(.failed(nil, "registration became unavailable"))

        let event = await iterator.next()
        XCTAssertEqual(
            event,
            .failed(nil, .device("registration became unavailable"))
        )

        await adapter.disconnect()
    }

    func testFailedConnectFinishesOnlyItsPublicSubscriptionAndCanRetry() async throws {
        let session = RestartableMetaSession(connectFailures: 1)
        let adapter = MetaDATAdapter(session: session)

        let failedStream = adapter.events()
        var failedIterator = failedStream.makeAsyncIterator()

        do {
            try await adapter.connect()
            XCTFail("Expected first connect to fail")
        } catch {}

        let failedResult = await failedIterator.next()
        XCTAssertNil(failedResult)

        let retryStream = adapter.events()
        var retryIterator = retryStream.makeAsyncIterator()
        try await adapter.connect()

        let id = UUID()
        session.emit(.sessionStarted(id))

        let retryEvent = await retryIterator.next()
        XCTAssertEqual(
            retryEvent,
            .sessionStarted(InteractionID(rawValue: id))
        )

        await adapter.disconnect()

        let counts = session.counts()
        XCTAssertEqual(counts.connects, 2)
        XCTAssertEqual(counts.disconnects, 2)
    }

    func testDisconnectCannotFinishReplacementSubscriptionInstalledWhileSuspended() async throws {
        let session = BlockingDisconnectMetaSession()
        let adapter = MetaDATAdapter(session: session)

        let firstStream = adapter.events()
        var firstIterator = firstStream.makeAsyncIterator()
        try await adapter.connect()

        let disconnect = Task { await adapter.disconnect() }
        await session.waitUntilDisconnectStarts()

        let replacementStream = adapter.events()
        var replacementIterator = replacementStream.makeAsyncIterator()

        // Replacing a subscriber terminates the old stream immediately.
        let firstResult = await firstIterator.next()
        XCTAssertNil(firstResult)

        session.releaseDisconnect()
        await disconnect.value

        // The disconnect captured the old generation before it suspended, so
        // the replacement must remain usable for the next connection.
        try await adapter.connect()
        let id = UUID()
        session.emit(.sessionStarted(id))

        let replacementEvent = await replacementIterator.next()
        XCTAssertEqual(
            replacementEvent,
            .sessionStarted(InteractionID(rawValue: id))
        )

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

    func connect() async throws { continuation.yield(event) }
    func disconnect() async { continuation.finish() }
    nonisolated func events() -> AsyncStream<MetaDATEvent> { stream }
}

private actor FailingConnectSession: MetaDATSession {
    nonisolated let capabilities: MetaDATCapabilities = []
    private(set) var disconnectCount = 0

    func connect() async throws { throw AWLError.device("connect failed") }
    func disconnect() async { disconnectCount += 1 }
    nonisolated func events() -> AsyncStream<MetaDATEvent> { AsyncStream { _ in } }
}


private actor VoiceStubSession: MetaDATSession, MetaDATVoiceInvocationSource {
    nonisolated let capabilities: MetaDATCapabilities = [.voiceInvocation]
    nonisolated private let eventStream: AsyncStream<MetaDATEvent>
    nonisolated private let invocationStream: AsyncStream<MetaDATInvocation>
    private let eventContinuation: AsyncStream<MetaDATEvent>.Continuation
    private let invocationContinuation: AsyncStream<MetaDATInvocation>.Continuation
    private let invocation: MetaDATInvocation

    init(invocation: MetaDATInvocation) {
        self.invocation = invocation
        let events = AsyncStream<MetaDATEvent>.makeStream()
        self.eventStream = events.stream
        self.eventContinuation = events.continuation
        let invocations = AsyncStream<MetaDATInvocation>.makeStream()
        self.invocationStream = invocations.stream
        self.invocationContinuation = invocations.continuation
    }

    func connect() async throws {}
    func disconnect() async {
        eventContinuation.finish()
        invocationContinuation.finish()
    }
    nonisolated func events() -> AsyncStream<MetaDATEvent> { eventStream }
    nonisolated func invocationEvents() -> AsyncStream<MetaDATInvocation> {
        invocationStream
    }
    func emitInvocation() { invocationContinuation.yield(invocation) }
}

private final class RestartableMetaSession: MetaDATSession, @unchecked Sendable {
    let capabilities: MetaDATCapabilities = []

    private let lock = NSLock()
    private var continuation: AsyncStream<MetaDATEvent>.Continuation?
    private var remainingConnectFailures: Int
    private var connectCount = 0
    private var disconnectCount = 0

    init(connectFailures: Int = 0) {
        self.remainingConnectFailures = connectFailures
    }

    func events() -> AsyncStream<MetaDATEvent> {
        let pair = AsyncStream<MetaDATEvent>.makeStream()
        let previous = lock.withLock { () -> AsyncStream<MetaDATEvent>.Continuation? in
            let previous = continuation
            continuation = pair.continuation
            return previous
        }
        previous?.finish()
        return pair.stream
    }

    func connect() async throws {
        let shouldFail = lock.withLock { () -> Bool in
            connectCount += 1
            guard remainingConnectFailures > 0 else { return false }
            remainingConnectFailures -= 1
            return true
        }
        if shouldFail {
            throw AWLError.device("connect failed")
        }
    }

    func disconnect() async {
        let active = lock.withLock { () -> AsyncStream<MetaDATEvent>.Continuation? in
            disconnectCount += 1
            let active = continuation
            continuation = nil
            return active
        }
        active?.finish()
    }

    func emit(_ event: MetaDATEvent) {
        let active = lock.withLock { continuation }
        active?.yield(event)
    }

    func counts() -> (connects: Int, disconnects: Int) {
        lock.withLock { (connectCount, disconnectCount) }
    }
}

private final class BlockingDisconnectMetaSession: MetaDATSession, @unchecked Sendable {
    let capabilities: MetaDATCapabilities = []

    private let lock = NSLock()
    private var continuation: AsyncStream<MetaDATEvent>.Continuation?
    private var disconnectStarted = false
    private var disconnectReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func events() -> AsyncStream<MetaDATEvent> {
        let pair = AsyncStream<MetaDATEvent>.makeStream()
        let previous = lock.withLock { () -> AsyncStream<MetaDATEvent>.Continuation? in
            let previous = continuation
            continuation = pair.continuation
            return previous
        }
        previous?.finish()
        return pair.stream
    }

    func connect() async throws {}

    func disconnect() async {
        let startWaiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            disconnectStarted = true
            let waiters = self.startWaiters
            self.startWaiters.removeAll()
            return waiters
        }
        for waiter in startWaiters { waiter.resume() }

        let shouldWait = lock.withLock { !disconnectReleased }
        if shouldWait {
            await withCheckedContinuation { waiter in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if disconnectReleased { return true }
                    releaseWaiters.append(waiter)
                    return false
                }
                if resumeImmediately { waiter.resume() }
            }
        }

        let active = lock.withLock { () -> AsyncStream<MetaDATEvent>.Continuation? in
            let active = continuation
            continuation = nil
            return active
        }
        active?.finish()
    }

    func waitUntilDisconnectStarts() async {
        let alreadyStarted = lock.withLock { disconnectStarted }
        if alreadyStarted { return }

        await withCheckedContinuation { waiter in
            let resumeImmediately = lock.withLock { () -> Bool in
                if disconnectStarted { return true }
                startWaiters.append(waiter)
                return false
            }
            if resumeImmediately { waiter.resume() }
        }
    }

    func releaseDisconnect() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            disconnectReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func emit(_ event: MetaDATEvent) {
        let active = lock.withLock { continuation }
        active?.yield(event)
    }
}

private actor BlockingSnapshotSession: MetaDATSnapshotSession {
    nonisolated let capabilities: MetaDATCapabilities = [.cameraSnapshot]
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}
    func disconnect() async {}
    nonisolated func events() -> AsyncStream<MetaDATEvent> { AsyncStream { _ in } }

    func captureSnapshotData() async throws -> MetaDATSnapshot {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()

        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return MetaDATSnapshot(data: Data([1]), format: .jpeg)
    }

    func waitUntilCaptureStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
