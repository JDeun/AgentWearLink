import MWDATCamera
import MWDATCore

public enum MetaDATCameraConfiguration {
    /// Minimal compressed stream used to attach the camera and wake its sensor.
    /// Photo readiness/start policy is owned by later slices (#130/#131).
    public static func attach(to session: DeviceSession, carriesAudio: Bool = false) throws -> Camera? {
        let configuration = StreamConfiguration(
            videoCodec: .hvc1,
            audioCodec: carriesAudio ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil,
            resolution: .low,
            frameRate: 7
        )
        return try session.addCamera(config: configuration)
    }
}
