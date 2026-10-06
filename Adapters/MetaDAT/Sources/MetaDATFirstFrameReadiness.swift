import MWDATCamera
import MWDATCore

/// Converts the first delivered video frame into a one-way camera-ready edge.
/// It does not inspect/render frame pixels; a frame is evidence that the remote
/// Meta camera sensor and video path are awake.
public final class MetaDATFirstFrameReadiness: @unchecked Sendable {
    private let tokens = ListenerTokenBag()
    private let lock = NSLock()
    private var ready = false

    public init() {}

    public func observe(_ stream: Stream, onReady: @escaping @Sendable () -> Void) {
        stream.videoFramePublisher.listen { [weak self] _ in
            guard let self else { return }
            let becameReady = self.lock.withLock { () -> Bool in
                guard !self.ready else { return false }
                self.ready = true
                return true
            }
            if becameReady { onReady() }
        }.store(in: tokens)
    }

    public func reset() {
        lock.withLock { ready = false }
        Task { await tokens.cancelAll() }
    }

    public var isReady: Bool { lock.withLock { ready } }
}
