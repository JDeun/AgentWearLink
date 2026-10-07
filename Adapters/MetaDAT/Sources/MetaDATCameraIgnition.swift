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

        case .waitingForDevice, .starting, .stopping:
            // These states are not camera-ready. Keep ignition non-restartable
            // until the SDK reports .stopped, but do not continue advertising
            // the stream as ready after it leaves .streaming.
            state = .starting

        case .paused:
            // A paused vendor stream still owns the established stream
            // generation. Do not treat it as a cold-camera loss or trigger a
            // duplicate start; readiness resumes when .streaming returns.
            break

        case .stopped:
            // A terminal vendor stop retires the current ignition generation
            // and permits a fresh start().
            state = .idle

        @unknown default:
            // Unknown future states are deliberately non-destructive. The SDK
            // must report a known terminal .stopped before AWL re-ignites.
            break
        }
    }

    public func stop(_ stream: Stream) {
        guard state != .idle else { return }
        stream.stop()
        state = .idle
    }
}
