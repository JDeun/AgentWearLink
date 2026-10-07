import AgentWearLinkCore
import Foundation

/// SDK-neutral boundary implemented by the iOS host that owns Meta Wearables DAT.
///
/// Keeping this protocol free of Meta types lets AWL exercise lifecycle and
/// capability semantics in CI without linking the vendor SDK. The concrete DAT
/// bridge belongs in the iOS reference application after P0-A validation.
public protocol MetaDATSession: Sendable {
    var capabilities: MetaDATCapabilities { get }
    func connect() async throws
    func disconnect() async
    func events() -> AsyncStream<MetaDATEvent>
}

/// Optional SDK-neutral still-camera surface implemented by a concrete DAT host.
/// The host owns MWDATCamera types and returns copied bytes only after an
/// explicit, user-authorized one-shot capture.
/// Optional voice-invocation channel owned independently from DeviceSession.
/// The concrete host must acknowledge Meta AI's invocation before yielding it
/// here so slow agent work never holds the platform response handle open.
public protocol MetaDATVoiceInvocationSource: Sendable {
    func invocationEvents() -> AsyncStream<MetaDATInvocation>
}

public struct MetaDATInvocation: Sendable, Equatable {
    public let id: UUID
    public let phrase: String?

    public init(id: UUID, phrase: String? = nil) {
        self.id = id
        self.phrase = phrase
    }
}

public protocol MetaDATSnapshotSession: MetaDATSession {
    func captureSnapshotData() async throws -> MetaDATSnapshot
}

public struct MetaDATSnapshot: Sendable, Equatable {
    public let data: Data
    public let format: ImageAttachment.Format

    public init(data: Data, format: ImageAttachment.Format) {
        self.data = data
        self.format = format
    }
}

public struct MetaDATCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let speech = Self(rawValue: 1 << 0)
    public static let rawAudio = Self(rawValue: 1 << 1)
    public static let cameraSnapshot = Self(rawValue: 1 << 2)
    public static let speaker = Self(rawValue: 1 << 3)
    public static let voiceInvocation = Self(rawValue: 1 << 4)
}

public enum MetaDATEvent: Sendable, Equatable {
    case sessionStarted(UUID)
    case transcript(UUID, String)
    case invocation(UUID, String?)
    case interrupted(UUID)
    case sessionEnded(UUID)
    case failed(UUID?, String)
}

/// Normalizes Meta DAT session semantics into AgentWearLink Core contracts.
private final class MetaDATInteractionEventSource: @unchecked Sendable {
    private static let bufferLimit = 64

    private struct Subscription {
        let generation: UInt64
        let continuation: AsyncStream<InteractionEvent>.Continuation
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var subscription: Subscription?

    func stream() -> AsyncStream<InteractionEvent> {
        AsyncStream(
            bufferingPolicy: .bufferingNewest(Self.bufferLimit)
        ) { continuation in
            lock.lock()
            nextGeneration &+= 1
            let previous = subscription
            subscription = Subscription(
                generation: nextGeneration,
                continuation: continuation
            )
            lock.unlock()

            previous?.continuation.finish()
        }
    }

    func currentGeneration() -> UInt64? {
        lock.lock()
        let generation = subscription?.generation
        lock.unlock()
        return generation
    }

    func yield(_ event: InteractionEvent) {
        lock.lock()
        let active = subscription
        lock.unlock()

        guard let active else { return }
        guard case .dropped = active.continuation.yield(event) else { return }

        // Device-to-Core delivery is deliberately bounded. If a consumer falls
        // behind far enough to drop an event, surface that loss explicitly and
        // retire only the overflowing subscription generation.
        _ = active.continuation.yield(
            .failed(
                event.interactionID,
                .overloaded("Meta DAT event stream buffer capacity exceeded")
            )
        )

        lock.lock()
        let shouldFinish = subscription?.generation == active.generation
        if shouldFinish {
            subscription = nil
        }
        lock.unlock()

        if shouldFinish {
            active.continuation.finish()
        }
    }

    func finish(generation: UInt64?) {
        guard let generation else { return }

        lock.lock()
        let continuation: AsyncStream<InteractionEvent>.Continuation?
        if subscription?.generation == generation {
            continuation = subscription?.continuation
            subscription = nil
        } else {
            continuation = nil
        }
        lock.unlock()

        continuation?.finish()
    }
}

public actor MetaDATAdapter: SnapshotCapturingDevice {
    private let session: any MetaDATSession
    private let mappedCapabilities: CapabilitySet
    private nonisolated let eventSource = MetaDATInteractionEventSource()
    private var eventTask: Task<Void, Never>?
    private var invocationTask: Task<Void, Never>?
    private var snapshotInFlight = false

    public nonisolated var capabilities: CapabilitySet { mappedCapabilities }

    public init(session: any MetaDATSession) {
        self.session = session
        self.mappedCapabilities = Self.mapCapabilities(session.capabilities)
    }

    public func connect() async throws {
        guard eventTask == nil else { return }

        // Public event subscriptions are connection-generation scoped. Runtime
        // callers install one before every connect; capture its generation so a
        // failed connect can finish only that subscription.
        let publicEventGeneration = eventSource.currentGeneration()

        // Subscribe before connect. A concrete DAT host may emit lifecycle or
        // failure events while establishing the device session.
        let stream = session.events()
        let forwardingTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.forward(event)
            }
        }
        eventTask = forwardingTask

        if mappedCapabilities.contains(.voiceInvocation) {
            guard let source = session as? any MetaDATVoiceInvocationSource else {
                forwardingTask.cancel()
                eventTask = nil
                eventSource.finish(generation: publicEventGeneration)
                throw AWLError.capabilityUnavailable(
                    "Meta DAT voice invocation is advertised without a concrete invocation source"
                )
            }
            let invocations = source.invocationEvents()
            invocationTask = Task { [weak self] in
                for await invocation in invocations {
                    guard !Task.isCancelled else { break }
                    await self?.forward(
                        .invocation(invocation.id, invocation.phrase)
                    )
                }
            }
        }

        do {
            try await session.connect()
        } catch {
            forwardingTask.cancel()
            invocationTask?.cancel()
            invocationTask = nil
            eventTask = nil
            await session.disconnect()
            eventSource.finish(generation: publicEventGeneration)
            throw AWLError.device(String(describing: error))
        }
    }

    public func captureSnapshot(
        interactionID: InteractionID
    ) async throws -> ImageAttachment {
        guard mappedCapabilities.contains(.cameraSnapshot) else {
            throw AWLError.capabilityUnavailable("Meta DAT camera snapshot is not advertised")
        }
        guard let snapshotSession = session as? any MetaDATSnapshotSession else {
            throw AWLError.capabilityUnavailable("Meta DAT camera snapshot bridge is unavailable")
        }
        guard !snapshotInFlight else {
            throw AWLError.device("Meta DAT snapshot capture is already in progress")
        }

        snapshotInFlight = true
        defer { snapshotInFlight = false }

        let snapshot = try await snapshotSession.captureSnapshotData()
        try Task.checkCancellation()
        return try ImageAttachment(data: snapshot.data, format: snapshot.format)
    }

    public func disconnect() async {
        // Snapshot the public subscription before yielding to the session.
        // A new subscription installed while disconnect is suspended belongs to
        // a later generation and must survive this teardown.
        let publicEventGeneration = eventSource.currentGeneration()

        eventTask?.cancel()
        invocationTask?.cancel()
        snapshotInFlight = false
        eventTask = nil
        invocationTask = nil
        await session.disconnect()
        eventSource.finish(generation: publicEventGeneration)
    }

    public nonisolated func events() -> AsyncStream<InteractionEvent> {
        eventSource.stream()
    }

    private func forward(_ event: MetaDATEvent) {
        let normalized: InteractionEvent
        switch event {
        case let .sessionStarted(id):
            normalized = .sessionStarted(InteractionID(rawValue: id))
        case let .transcript(id, text):
            normalized = .text(InteractionID(rawValue: id), text)
        case let .invocation(id, phrase):
            normalized = .invocation(InteractionID(rawValue: id), phrase)
        case let .interrupted(id):
            normalized = .interrupted(InteractionID(rawValue: id))
        case let .sessionEnded(id):
            normalized = .sessionEnded(InteractionID(rawValue: id))
        case let .failed(id, message):
            normalized = .failed(id.map { InteractionID(rawValue: $0) }, .device(message))
        }
        eventSource.yield(normalized)
    }

    private nonisolated static func mapCapabilities(_ source: MetaDATCapabilities) -> CapabilitySet {
        var result: CapabilitySet = []
        if source.contains(.speech) { result.insert(.speechInput) }
        if source.contains(.rawAudio) { result.insert(.rawAudioInput) }
        if source.contains(.cameraSnapshot) { result.insert(.cameraSnapshot) }
        if source.contains(.speaker) { result.insert(.speakerOutput) }
        if source.contains(.voiceInvocation) { result.insert(.voiceInvocation) }
        return result
    }
}
