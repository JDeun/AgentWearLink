import AgentWearLinkCore
import AgentWearLinkOpenClaw
import XCTest

final class PhotoTurnTests: XCTestCase {
    private static let jpeg = try! ImageAttachment(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), format: .jpeg)

    func testVisualRequestCapturesAndSendsImageTurn() async throws {
        let inner = RecordingVisionAgent(supportsVisionInput: true)
        let events = EventBox()
        let agent = PhotoTurnAgent(inner: inner, enabled: true, capture: { _ in .photo(Self.jpeg) }, observe: events.add)
        let id = InteractionID()
        for try await _ in await agent.responses(for: AgentRequest(interactionID: id, text: "이거 뭐야?")) {}
        let vision = await inner.visionRequests
        XCTAssertEqual(vision.count, 1)
        XCTAssertEqual(vision.first?.prompt, "이거 뭐야?")
        XCTAssertEqual(vision.first?.image, Self.jpeg)
        let texts = await inner.textRequests
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(events.all, [.intent(.demonstrative), .sentWithPhoto])
    }

    func testNonVisualRequestNeverTouchesTheCamera() async throws {
        let inner = RecordingVisionAgent(supportsVisionInput: true)
        let captured = EventBox()
        let agent = PhotoTurnAgent(inner: inner, enabled: true, capture: { _ in
            captured.add(.sentWithPhoto)
            return .photo(Self.jpeg)
        })
        for try await _ in await agent.responses(for: AgentRequest(interactionID: InteractionID(), text: "오늘 일정 뭐야")) {}
        XCTAssertTrue(captured.all.isEmpty)
        let texts = await inner.textRequests
        XCTAssertEqual(texts.map(\.text), ["오늘 일정 뭐야"])
    }

    func testDisabledOrTextOnlyAgentPassesThrough() async throws {
        for (enabled, vision) in [(false, true), (true, false)] {
            let inner = RecordingVisionAgent(supportsVisionInput: vision)
            let agent = PhotoTurnAgent(inner: inner, enabled: enabled, capture: { _ in
                XCTFail("camera must stay off")
                return .unavailable(reason: "x")
            })
            for try await _ in await agent.responses(for: AgentRequest(interactionID: InteractionID(), text: "이거 뭐야")) {}
            let texts = await inner.textRequests
            XCTAssertEqual(texts.map(\.text), ["이거 뭐야"])
        }
    }

    func testCaptureFailureSendsTextWithNote() async throws {
        let inner = RecordingVisionAgent(supportsVisionInput: true)
        let events = EventBox()
        let agent = PhotoTurnAgent(inner: inner, enabled: true, capture: { _ in .unavailable(reason: "heat") }, observe: events.add)
        for try await _ in await agent.responses(for: AgentRequest(interactionID: InteractionID(), text: "what is this")) {}
        let texts = await inner.textRequests
        XCTAssertEqual(texts.map(\.text), [PhotoTurnText.unavailableNote + "what is this"])
        XCTAssertEqual(events.all, [.intent(.english), .sentWithoutPhoto(reason: "heat")])
    }

    func testGatewayWithoutAttachmentsFallsBackToTextOnce() async throws {
        let inner = RecordingVisionAgent(supportsVisionInput: true, visionError: AWLOpenClawError.attachmentsUnavailable)
        let events = EventBox()
        let agent = PhotoTurnAgent(inner: inner, enabled: true, capture: { _ in .photo(Self.jpeg) }, observe: events.add)
        var texts: [String] = []
        for try await response in await agent.responses(for: AgentRequest(interactionID: InteractionID(), text: "이거 뭐야")) {
            if case let .textDelta(_, text) = response { texts.append(text) }
        }
        XCTAssertEqual(texts, ["ok"])
        let sent = await inner.textRequests
        XCTAssertEqual(sent.map(\.text), [PhotoTurnText.unavailableNote + "이거 뭐야"])
        XCTAssertEqual(events.all, [.intent(.demonstrative), .sentWithPhoto, .imageRejected])
    }

    func testFailureAfterSubmissionIsNotRetried() async {
        let inner = RecordingVisionAgent(supportsVisionInput: true, visionError: AWLError.transport("lost"))
        let agent = PhotoTurnAgent(inner: inner, enabled: true, capture: { _ in .photo(Self.jpeg) })
        do {
            for try await _ in await agent.responses(for: AgentRequest(interactionID: InteractionID(), text: "이거 뭐야")) {}
            XCTFail("expected the error")
        } catch {
            XCTAssertEqual(error as? AWLError, .transport("lost"))
        }
        let sent = await inner.textRequests
        XCTAssertTrue(sent.isEmpty)
    }

    func testMusicReminderPolicyAndLog() {
        XCTAssertTrue(PhotoMusicPolicy.shouldRemind(enabled: true, playingBefore: true, playingNow: false))
        XCTAssertFalse(PhotoMusicPolicy.shouldRemind(enabled: false, playingBefore: true, playingNow: false))
        XCTAssertFalse(PhotoMusicPolicy.shouldRemind(enabled: true, playingBefore: false, playingNow: false))
        XCTAssertFalse(PhotoMusicPolicy.shouldRemind(enabled: true, playingBefore: true, playingNow: true))
        XCTAssertEqual(PhotoMusicPolicy.reminder(korean: true), "음악은 iPhone에서 다시 재생해 주세요.")
        var watch = PhotoMusicWatch(playingBefore: true)
        XCTAssertFalse(watch.stoppedByPhoto)
        watch.afterOneSecond = false
        XCTAssertTrue(watch.stoppedByPhoto)
        watch.afterFourSeconds = true
        XCTAssertFalse(watch.stoppedByPhoto, "music came back by itself")
        XCTAssertEqual(watch.logLine, "music around photo: before 1, +1 s 0, +4 s 1")
    }

    func testPhotoOnlyAtNormalHeat() {
        XCTAssertTrue(ThermalWorkPolicy.allowsPhoto(stage: .normal))
        XCTAssertFalse(ThermalWorkPolicy.allowsPhoto(stage: .reduced))
        XCTAssertFalse(ThermalWorkPolicy.allowsPhoto(stage: .shed))
    }

    func testShutterIsQuietAndShort() {
        let tones = Earcon.shutter.tones
        XCTAssertLessThan(tones.map(\.duration).reduce(0, +), 0.08)
        XCTAssertLessThanOrEqual(tones.map(\.gain).max() ?? 1, Earcon.accepted.tones.map(\.gain).min() ?? 0)
    }

    func testPhotoMetrics() {
        var metrics = QualityMetrics(now: Date(timeIntervalSince1970: 1_000_000))
        let now = Date(timeIntervalSince1970: 1_000_010)
        metrics.photoTurn(at: now)
        metrics.photoCaptured(seconds: 2.0, at: now)
        metrics.photoCaptured(seconds: 3.0, at: now)
        metrics.photoFailed(at: now)
        XCTAssertEqual(metrics.today.photoTurns, 1)
        XCTAssertEqual(metrics.today.photoFailures, 1)
        XCTAssertEqual(metrics.sinceLaunch.photoTurns, 1)
        XCTAssertEqual(metrics.lastPhotoCapture, 3.0)
        XCTAssertEqual(metrics.medianPhotoCaptureToday, 2.5)
    }

    func testSettingsPersistPhotoOptions() {
        let defaults = UserDefaults(suiteName: "photo-\(UUID().uuidString)")!
        let store = CompanionSettingsStore(defaults: defaults)
        XCTAssertTrue(store.load().visionRequests)
        XCTAssertTrue(store.load().photoMusicHint)
        XCTAssertEqual(store.load().photoCaptureMethod, .streamStill)
        var settings = CompanionSettings()
        settings.visionRequests = false
        settings.photoMusicHint = false
        settings.photoCaptureMethod = .standalonePhoto
        store.save(settings)
        let loaded = store.load()
        XCTAssertFalse(loaded.visionRequests)
        XCTAssertFalse(loaded.photoMusicHint)
        XCTAssertEqual(loaded.photoCaptureMethod, .standalonePhoto)
        store.reset()
        XCTAssertTrue(store.load().visionRequests)
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PhotoTurnEvent] = []
    var add: @Sendable (PhotoTurnEvent) -> Void {
        { [self] event in lock.withLock { events.append(event) } }
    }
    var all: [PhotoTurnEvent] { lock.withLock { events } }
}

private actor RecordingVisionAgent: VisionAgentAdapter {
    nonisolated let supportsVisionInput: Bool
    private let visionError: Error?
    private(set) var textRequests: [AgentRequest] = []
    private(set) var visionRequests: [VisionRequest] = []

    init(supportsVisionInput: Bool, visionError: Error? = nil) {
        self.supportsVisionInput = supportsVisionInput
        self.visionError = visionError
    }

    func connect() async throws {}
    func disconnect() async {}
    func cancel(interactionID: InteractionID) async {}

    func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        textRequests.append(request)
        return Self.reply(request.interactionID)
    }

    func responses(for request: VisionRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        visionRequests.append(request)
        if let visionError {
            return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { $0.finish(throwing: visionError) }
        }
        return Self.reply(request.interactionID)
    }

    private static func reply(_ id: InteractionID) -> AsyncThrowingStream<AgentResponse, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(4)) { continuation in
            continuation.yield(.textDelta(id, "ok"))
            continuation.yield(.completed(id))
            continuation.finish()
        }
    }
}
