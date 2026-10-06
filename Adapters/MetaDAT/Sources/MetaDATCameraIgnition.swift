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
        switch streamState {
        case .streaming:
            state = .streaming
        case .stopped:
            state = .idle
        case .starting, .waitingForDevice, .stopping, .paused:
            break
        @unknown default:
            break
        }
    }

    public func stop(_ stream: Stream) {
        guard state != .idle else { return }
        stream.stop()
        state = .idle
    }
}
