import MWDATCamera

/// Owns only the cold-camera ignition transition. Photo readiness and shutter
/// behavior are separate slices so ignition cannot accidentally capture media.
public actor MetaDATCameraIgnition {
    public enum State: Sendable, Equatable { case idle, starting, streaming }
    public private(set) var state: State = .idle

    public init() {}

    public func start(_ stream: Stream) {
        guard state == .idle else { return }
        state = .starting
        stream.start()
    }

    public func observe(_ streamState: StreamState) {
        guard state == .starting else { return }
        if streamState == .streaming { state = .streaming }
    }

    public func stop(_ stream: Stream) {
        guard state != .idle else { return }
        stream.stop()
        state = .idle
    }
}
