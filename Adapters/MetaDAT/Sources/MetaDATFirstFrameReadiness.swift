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
    ) {
        let listenerGeneration = generation.begin()
        let retiredToken = lock.withLock { () -> (any AnyListenerToken)? in
            defer { token = nil }
            return token
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
    }

    public func reset() {
        generation.invalidate()
        let retiredToken = lock.withLock { () -> (any AnyListenerToken)? in
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
