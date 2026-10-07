import Foundation

/// Host lifecycle signal consumed by the Meta integration layer without
/// introducing UIKit/SwiftUI types into AgentWearLink Core.
public enum MetaDATApplicationPhase: Sendable, Equatable {
    case foreground
    case background
}

final class MetaDATApplicationPhaseSource: @unchecked Sendable {
    private struct Subscription {
        let generation: UInt64
        let continuation: AsyncStream<MetaDATApplicationPhase>.Continuation
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var phase: MetaDATApplicationPhase
    private var subscription: Subscription?

    init(initialPhase: MetaDATApplicationPhase) {
        self.phase = initialPhase
    }

    var currentPhase: MetaDATApplicationPhase {
        lock.lock()
        let value = phase
        lock.unlock()
        return value
    }

    func stream() -> AsyncStream<MetaDATApplicationPhase> {
        // A pending background event must not be replaced by a rapid
        // background -> foreground transition before the consumer runs.
        // Retain the initial snapshot and the first transition; the adapter
        // retires its media generation on the first background observation.
        // Consumers requiring the latest UI state must use currentPhase.
        AsyncStream(bufferingPolicy: .bufferingOldest(2)) { continuation in
            lock.lock()
            nextGeneration &+= 1
            let generation = nextGeneration
            let previous = subscription
            subscription = Subscription(
                generation: generation,
                continuation: continuation
            )
            _ = continuation.yield(phase)
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(generation: generation)
            }
            previous?.continuation.finish()
        }
    }

    func transition(to nextPhase: MetaDATApplicationPhase) {
        lock.lock()
        guard nextPhase != phase else {
            lock.unlock()
            return
        }
        phase = nextPhase
        let active = subscription
        lock.unlock()

        guard let active else { return }
        if case .terminated = active.continuation.yield(nextPhase) {
            remove(generation: active.generation)
        }
    }

    private func remove(generation: UInt64) {
        lock.lock()
        if subscription?.generation == generation {
            subscription = nil
        }
        lock.unlock()
    }
}

public actor MetaDATApplicationLifecycle {
    private nonisolated let source: MetaDATApplicationPhaseSource

    public init(initialPhase: MetaDATApplicationPhase) {
        self.source = MetaDATApplicationPhaseSource(initialPhase: initialPhase)
    }

    public var currentPhase: MetaDATApplicationPhase {
        source.currentPhase
    }

    public nonisolated func phases() -> AsyncStream<MetaDATApplicationPhase> {
        source.stream()
    }

    public func transition(to phase: MetaDATApplicationPhase) {
        source.transition(to: phase)
    }
}
