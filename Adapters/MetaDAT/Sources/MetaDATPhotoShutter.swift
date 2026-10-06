import MWDATCamera

/// Narrow one-shot shutter seam. A false SDK return is a synchronous rejection;
/// callers must not wait for a photo event that cannot arrive.
public enum MetaDATPhotoShutter {
    public static func trigger(_ stream: MWDATCamera.Stream) -> Bool {
        stream.capturePhoto(format: .jpeg)
    }
}
