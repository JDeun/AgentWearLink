import Foundation
import MWDATCamera
import MWDATCore

/// Converts the first delivered video frame into a one-way camera-ready edge.
/// It does not inspect/render frame pixels; a frame is evidence that the remote
/// Meta camera sensor and video path are awake.
public final class MetaDATFirstFrameReadiness: @unchecked Sendable {
    private let generation = MetaDATListenerGeneration()
    private let lock = NSLock()
    private var token: (any AnyListenerToken)?
    private var ready = false

    public init() {}

    public func observe(
        _ stream: MWDATCamera.Stream,
        onReady: @escaping @Sendable () -> Void
    ) -> UInt64 {
        let (listenerGeneration, retiredToken) = lock.withLock {
            let lease = generation.begin()
            let previous = token
            token = nil
            ready = false
            return (lease, previous)
        }
        if let retiredToken {
            Task { await retiredToken.cancel() }
        }

        let gate = generation
        let newToken = stream.videoFramePublisher.listen { [weak self] _ in
            guard let self, gate.isCurrent(listenerGeneration) else { return }
            let becameReady = self.lock.withLock { () -> Bool in
                guard gate.isCurrent(listenerGeneration), !self.ready else {
                    return false
                }
                self.ready = true
                return true
            }
            if becameReady {
                onReady()
            }
        }

        let shouldCancelNewToken = lock.withLock { () -> Bool in
            guard generation.isCurrent(listenerGeneration) else {
                return true
            }
            token = newToken
            return false
        }
        if shouldCancelNewToken {
            Task { await newToken.cancel() }
        }
        return listenerGeneration
    }

    public func reset() {
        reset(ifCurrent: nil)
    }

    /// An old AsyncStream.onTermination may run after the next frame listener
    /// starts. Only its own lease can reset readiness and cancel the token.
    public func reset(ifCurrent lease: UInt64?) {
        let retiredToken = lock.withLock { () -> (any AnyListenerToken)? in
            if let lease {
                guard generation.invalidate(ifCurrent: lease) else { return nil }
            } else {
                generation.invalidate()
            }
            ready = false
            defer { token = nil }
            return token
        }
        if let retiredToken {
            Task { await retiredToken.cancel() }
        }
    }

    public var isReady: Bool {
        lock.withLock { ready }
    }
}
