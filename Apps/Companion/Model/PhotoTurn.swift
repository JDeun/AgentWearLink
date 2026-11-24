import AgentWearLinkCore
import AgentWearLinkOpenClaw
import Foundation

/// "사진 찍는 방식" (Settings › Advanced).
public enum PhotoCaptureMethod: String, CaseIterable, Equatable, Sendable {
    /// GA path: a short low-resolution camera stream, one still from it,
    /// stream stopped at once. Default.
    case streamStill
    /// EXPERIMENT: DAT standalone Photo (experimental in DAT 1.0, dev/beta
    /// release channel only; DEBUG builds only in AWL).
    case standalonePhoto
}

/// What the camera produced for one photo turn.
public enum PhotoCaptureOutcome: Sendable, Equatable {
    case photo(ImageAttachment)
    /// No photo; `reason` is a stable category for the log.
    case unavailable(reason: String)
}

/// Text for the agent around a photo turn.
public enum PhotoTurnText {
    /// Appended to the system prompt of image turns only.
    public static let visionHint = """
    이 요청에는 사용자가 쓴 스마트 안경 카메라로 방금 찍은 사진 한 장이 첨부되어 있습니다. \
    사진은 사용자가 지금 보고 있는 장면이고, "이거", "저거"는 사진 속 대상을 가리킵니다. \
    사진을 근거로 답하고, 사진이 흐리거나 대상이 안 보이면 그렇다고 짧게 말하세요.
    """

    /// Prefixed to the request when the photo could not be taken, so the
    /// agent does not pretend to see.
    public static let unavailableNote = "[안경 카메라로 사진을 찍지 못했습니다. 사진 없이 답해 주세요.] "
}

/// "사진 후 음악 안내". A DAT camera stream pauses A2DP music and does not
/// resume it (dat-ios #256, open). After such a turn the reply ends with
/// one short line. The line points at the iPhone: while our DAT session
/// runs, a single temple tap is the session's own pause/resume (dat-ios
/// #312), so "tap the glasses" would pause our session instead of the
/// music; whether a tap still reaches the music player then is unverified.
public enum PhotoMusicPolicy {
    public static func reminder(korean: Bool) -> String {
        korean ? "음악은 iPhone에서 다시 재생해 주세요." : "Please resume your music on your iPhone."
    }

    /// Speak the line only when music played before the photo and is still
    /// not playing when the reply has finished.
    public static func shouldRemind(enabled: Bool, playingBefore: Bool, playingNow: Bool) -> Bool {
        enabled && playingBefore && !playingNow
    }
}

/// Other-audio state around one photo (booleans only).
public struct PhotoMusicWatch: Equatable, Sendable {
    public let playingBefore: Bool
    public var afterOneSecond: Bool?
    public var afterFourSeconds: Bool?

    public init(playingBefore: Bool) { self.playingBefore = playingBefore }

    /// Music was playing and a later check found it stopped.
    public var stoppedByPhoto: Bool {
        playingBefore && (afterFourSeconds ?? afterOneSecond) == false
    }

    public var logLine: String {
        func b(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "—" }
        return "music around photo: before \(b(playingBefore)), +1 s \(b(afterOneSecond)), +4 s \(b(afterFourSeconds))"
    }
}

/// Wraps the agent adapter: a request that `VisionIntent` marks as visual
/// takes one photo first and goes out as an image turn; every other
/// request passes through untouched. The photo lives only in this call
/// (and the agent adapter's submission); nothing here keeps or logs it.
public struct PhotoTurnAgent: AgentAdapter {
    public typealias Capture = @Sendable (InteractionID) async -> PhotoCaptureOutcome
    public typealias Observer = @Sendable (PhotoTurnEvent) -> Void

    private let inner: any VisionAgentAdapter
    private let enabled: Bool
    private let capture: Capture
    private let observe: Observer

    public init(
        inner: any VisionAgentAdapter,
        enabled: Bool,
        capture: @escaping Capture,
        observe: @escaping Observer = { _ in }
    ) {
        self.inner = inner
        self.enabled = enabled
        self.capture = capture
        self.observe = observe
    }

    public func connect() async throws { try await inner.connect() }
    public func disconnect() async { await inner.disconnect() }
    public func cancel(interactionID: InteractionID) async { await inner.cancel(interactionID: interactionID) }
    public func cancellationOutcome(interactionID: InteractionID) async -> AgentCancellationOutcome {
        await inner.cancellationOutcome(interactionID: interactionID)
    }

    public func responses(for request: AgentRequest) async -> AsyncThrowingStream<AgentResponse, Error> {
        guard enabled, inner.supportsVisionInput, let reason = VisionIntent.reason(for: request.text) else {
            return await inner.responses(for: request)
        }
        observe(.intent(reason))
        switch await capture(request.interactionID) {
        case let .photo(image):
            if Task.isCancelled {
                return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) {
                    $0.finish(throwing: CancellationError())
                }
            }
            observe(.sentWithPhoto)
            let vision = await inner.responses(
                for: VisionRequest(interactionID: request.interactionID, prompt: request.text, image: image)
            )
            return fallingBack(vision, to: request)
        case let .unavailable(reason):
            observe(.sentWithoutPhoto(reason: reason))
            return await inner.responses(for: Self.textOnly(request))
        }
    }

    /// If the Gateway refuses the image before the run starts (no
    /// attachment support, too large), ask again without it. Anything after
    /// submission is not retried, so a run is never duplicated.
    private func fallingBack(
        _ vision: AsyncThrowingStream<AgentResponse, Error>,
        to request: AgentRequest
    ) -> AsyncThrowingStream<AgentResponse, Error> {
        let inner = inner
        let observe = observe
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(AgentResponse.defaultBufferLimit)) { continuation in
            let task = Task {
                var yielded = false
                do {
                    for try await response in vision {
                        yielded = true
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    guard !yielded, Self.isImageRejectedBeforeSubmission(error), !Task.isCancelled else {
                        continuation.finish(throwing: error)
                        return
                    }
                    observe(.imageRejected)
                    do {
                        for try await response in await inner.responses(for: Self.textOnly(request)) {
                            continuation.yield(response)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func textOnly(_ request: AgentRequest) -> AgentRequest {
        AgentRequest(interactionID: request.interactionID, text: PhotoTurnText.unavailableNote + request.text)
    }

    static func isImageRejectedBeforeSubmission(_ error: Error) -> Bool {
        if let error = error as? AWLOpenClawError {
            switch error {
            case .attachmentsUnavailable, .invalidAttachment, .imageAttachmentTooLarge, .attachmentBudgetExceeded:
                return true
            default:
                return false
            }
        }
        if case .capabilityUnavailable = error as? AWLError { return true }
        return false
    }
}

/// For the activity log and the quality counters (categories only).
public enum PhotoTurnEvent: Equatable, Sendable {
    case intent(VisionIntent.Reason)
    case sentWithPhoto
    case sentWithoutPhoto(reason: String)
    case imageRejected
}
