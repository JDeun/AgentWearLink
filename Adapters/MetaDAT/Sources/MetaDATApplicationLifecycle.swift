import Foundation

/// Host lifecycle signal consumed by the Meta integration layer without
/// introducing UIKit/SwiftUI types into AgentWearLink Core.
public enum MetaDATApplicationPhase: Sendable, Equatable {
    case foreground
    case background
}

public actor MetaDATApplicationLifecycle {
    private var continuation: AsyncStream<MetaDATApplicationPhase>.Continuation?
    public private(set) var currentPhase: MetaDATApplicationPhase

    public init(initialPhase: MetaDATApplicationPhase) {
        self.currentPhase = initialPhase
    }

    public nonisolated func phases() -> AsyncStream<MetaDATApplicationPhase> {
        AsyncStream { continuation in
            Task { await self.install(continuation) }
        }
    }

    public func transition(to phase: MetaDATApplicationPhase) {
        guard phase != currentPhase else { return }
        currentPhase = phase
        continuation?.yield(phase)
    }

    private func install(_ continuation: AsyncStream<MetaDATApplicationPhase>.Continuation) {
        self.continuation?.finish()
        self.continuation = continuation
        continuation.yield(currentPhase)
    }
}
