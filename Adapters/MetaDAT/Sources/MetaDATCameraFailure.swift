import Foundation
import MWDATCamera

/// Redacted typed capture failure, never an SDK description or device identifier.
/// A camera refusal is local to the capture; only a DeviceSessionError proves
/// that the entire media session needs to retire.
public enum MetaDATCameraFailure: String, Error, Sendable, Equatable {
    case thermalHot
    case batteryLow
    case peakPowerLimit
    case deviceHealthCritical
    case streamFailed

    public init(_ error: StreamError) {
        switch error {
        case .thermalHot: self = .thermalHot
        case .batteryLow: self = .batteryLow
        case .peakPowerLimit: self = .peakPowerLimit
        default: self = .streamFailed
        }
    }

    public var isPowerRefusal: Bool { self != .streamFailed }
}

/// One latch for the entire Stream capture (start -> first frame -> shutter ->
/// transfer). The same SDK error listener is armed before start and survives
/// the phase transition. A late callback can only affect its own latch.
final class MetaDATCameraFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: MetaDATCameraFailure?
    private var onFailure: (@Sendable (MetaDATCameraFailure) -> Void)?

    func record(_ value: MetaDATCameraFailure) {
        let handler: (@Sendable (MetaDATCameraFailure) -> Void)? = lock.withLock {
            guard failure == nil else { return nil }
            failure = value
            return onFailure
        }
        handler?(value)
    }

    func observe(_ handler: @escaping @Sendable (MetaDATCameraFailure) -> Void) {
        let recorded = lock.withLock {
            onFailure = handler
            return failure
        }
        if let recorded { handler(recorded) }
    }

    func check() throws {
        if let failure = lock.withLock({ self.failure }) { throw failure }
    }
}
