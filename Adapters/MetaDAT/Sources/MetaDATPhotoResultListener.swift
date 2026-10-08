import Foundation
import MWDATCamera
import MWDATCore

/// Arms photo delivery before a shutter command can be issued.
///
/// Each arm owns exactly one SDK token. Cancellation invalidates the generation
/// synchronously before cancelling that exact token asynchronously, so a late
/// callback from the retired listener cannot cross into a re-armed listener.
public final class MetaDATPhotoResultListener: @unchecked Sendable {
    private let generation = MetaDATListenerGeneration()
    private let lock = NSLock()
    private var token: (any AnyListenerToken)?
    private var errorToken: (any AnyListenerToken)?

    public init() {}

    public func arm(
        _ stream: MWDATCamera.Stream,
        onData: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable () -> Void
    ) -> UInt64 {
        let (listenerGeneration, retired) = lock.withLock { () -> (UInt64, [any AnyListenerToken]) in
            let lease = generation.begin()
            let old = [token, errorToken].compactMap { $0 }
            token = nil
            errorToken = nil
            return (lease, old)
        }
        for retiredToken in retired {
            Task { await retiredToken.cancel() }
        }

        let gate = generation
        let newToken = stream.photoDataPublisher.listen { photoData in
            guard gate.isCurrent(listenerGeneration) else { return }
            onData(photoData.data)
        }

        let newErrorToken = stream.errorPublisher.listen { _ in
            guard gate.isCurrent(listenerGeneration) else { return }
            onError()
        }

        let shouldCancelNewTokens = lock.withLock { () -> Bool in
            guard generation.isCurrent(listenerGeneration) else {
                return true
            }
            token = newToken
            errorToken = newErrorToken
            return false
        }
        if shouldCancelNewTokens {
            Task {
                await newToken.cancel()
                await newErrorToken.cancel()
            }
        }
        return listenerGeneration
    }

    public func cancel() {
        cancel(ifCurrent: nil)
    }

    /// A previous photo stream may finish asynchronously after re-arming.
    /// Compare and retire under the same lock as arm() to preserve the new
    /// listener's callback and error tokens.
    public func cancel(ifCurrent lease: UInt64?) {
        let retired = lock.withLock { () -> [any AnyListenerToken] in
            if let lease {
                guard generation.invalidate(ifCurrent: lease) else { return [] }
            } else {
                generation.invalidate()
            }
            let old = [token, errorToken].compactMap { $0 }
            token = nil
            errorToken = nil
            return old
        }
        for retiredToken in retired {
            Task { await retiredToken.cancel() }
        }
    }
}
