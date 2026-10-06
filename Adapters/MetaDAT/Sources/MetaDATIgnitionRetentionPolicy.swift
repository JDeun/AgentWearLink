/// Decides whether the ignition video stream stays alive after camera readiness.
/// Audio ownership is the only reason to retain it; photo-only flows stop ignition.
public enum MetaDATIgnitionRetentionPolicy: Sendable {
    case photoOnly
    case carriesAudio

    public var shouldRetainAfterReadiness: Bool {
        switch self {
        case .photoOnly: false
        case .carriesAudio: true
        }
    }
}
