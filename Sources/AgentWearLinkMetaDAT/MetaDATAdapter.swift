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
    private let lock = NSLock()
    private var continuation: AsyncStream<InteractionEvent>.Continuation?

    func stream() -> AsyncStream<InteractionEvent> {
        AsyncStream { continuation in
            lock.lock()
            let previous = self.continuation
            self.continuation = continuation
            lock.unlock()

            previous?.finish()
        }
    }

    func yield(_ event: InteractionEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

public actor MetaDATAdapter: SnapshotCapturingDevice {
    private let session: any MetaDATSession
    private let mappedCapabilities: CapabilitySet
    private nonisolated let eventSource = MetaDATInteractionEventSource()
    private var eventTask: Task<Void, Never>?

    public nonisolated var capabilities: CapabilitySet { mappedCapabilities }

    public init(session: any MetaDATSession) {
        self.session = session
        self.mappedCapabilities = Self.mapCapabilities(session.capabilities)
    }

    public func connect() async throws {
        guard eventTask == nil else { return }
        do {
            try await session.connect()
        } catch {
            throw AWLError.device(String(describing: error))
        }

        let stream = session.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.forward(event)
            }
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

        let snapshot = try await snapshotSession.captureSnapshotData()
        return try ImageAttachment(data: snapshot.data, format: snapshot.format)
    }

    public func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await session.disconnect()
        eventSource.finish()
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
