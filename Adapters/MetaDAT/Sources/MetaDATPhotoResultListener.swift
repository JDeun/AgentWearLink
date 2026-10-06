import Foundation
import MWDATCamera
import MWDATCore

/// Arms photo delivery before a shutter command can be issued.
public final class MetaDATPhotoResultListener: @unchecked Sendable {
    private let tokens = ListenerTokenBag()

    public init() {}

    public func arm(_ stream: MWDATCamera.Stream, onData: @escaping @Sendable (Data) -> Void) {
        stream.photoDataPublisher.listen { photoData in
            onData(photoData.data)
        }.store(in: tokens)
    }

    public func cancel() { Task { await tokens.cancelAll() } }
}
