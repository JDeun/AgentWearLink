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
    ) {
        let listenerGeneration = generation.begin()
        let retired = lock.withLock { () -> [any AnyListenerToken] in
            defer {
                token = nil
                errorToken = nil
            }
            return [token, errorToken].compactMap { $0 }
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
    }

    public func cancel() {
        generation.invalidate()
        let retired = lock.withLock { () -> [any AnyListenerToken] in
            defer {
                token = nil
                errorToken = nil
            }
            return [token, errorToken].compactMap { $0 }
        }
        for retiredToken in retired {
            Task { await retiredToken.cancel() }
        }
    }
}
