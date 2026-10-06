import MWDATCamera

/// Owns the media resources that must be invalidated when the host backgrounds.
/// Foreground reacquisition is deliberately separate (#160).
public actor MetaDATBackgroundMediaInvalidator {
    private var camera: Camera?

    public init() {}

    public func install(camera: Camera) {
        self.camera = camera
    }

    public func handle(_ phase: MetaDATApplicationPhase) {
        guard phase == .background else { return }
        camera?.stream.stop()
        camera?.stop()
        camera = nil
    }

    public var hasCamera: Bool { camera != nil }
}
