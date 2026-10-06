/// Deterministic failure modes used by the app-hosted Meta mock harness.
/// The concrete MockDeviceKit client translates these into vendor injection calls.
public enum MetaDATMockCaptureFailure: Sendable, Equatable {
    case captureRejected
    case transferFailed

    public var message: String {
        switch self {
        case .captureRejected: "mock capture rejected"
        case .transferFailed: "mock capture transfer failed"
        }
    }
}
