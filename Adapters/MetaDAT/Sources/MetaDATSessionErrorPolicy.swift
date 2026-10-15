import Foundation
import MWDATCore

/// Every public `DeviceSessionError` case (DAT iOS 1.0.0 headers), by name
/// only. The vendor description (and `unexpectedError`'s payload) is never
/// carried: it may echo device or account details.
public enum MetaDATSessionErrorKind: String, CaseIterable, Sendable {
    case noEligibleDevice
    case sessionAlreadyStopped
    case sessionAlreadyExists
    case sessionIdle
    case capabilityAlreadyActive
    case capabilityNotFound
    case unexpectedError
    case thermalCritical
    case thermalEmergency
    case peakPowerShutdown
    case batteryCritical
    case datAppOnTheGlassesUpdateRequired
    case dwaUnavailable
    case insufficientSDKVersion
    case dwaOutOfStuRange

    public init(_ error: DeviceSessionError) {
        switch error {
        case .noEligibleDevice: self = .noEligibleDevice
        case .sessionAlreadyStopped: self = .sessionAlreadyStopped
        case .sessionAlreadyExists: self = .sessionAlreadyExists
        case .sessionIdle: self = .sessionIdle
        case .capabilityAlreadyActive: self = .capabilityAlreadyActive
        case .capabilityNotFound: self = .capabilityNotFound
        case .unexpectedError: self = .unexpectedError
        case .thermalCritical: self = .thermalCritical
        case .thermalEmergency: self = .thermalEmergency
        case .peakPowerShutdown: self = .peakPowerShutdown
        case .batteryCritical: self = .batteryCritical
        case .datAppOnTheGlassesUpdateRequired: self = .datAppOnTheGlassesUpdateRequired
        case .dwaUnavailable: self = .dwaUnavailable
        case .insufficientSDKVersion: self = .insufficientSDKVersion
        case .dwaOutOfStuRange: self = .dwaOutOfStuRange
        @unknown default: self = .unexpectedError
        }
    }

    /// The kind of a thrown error, or nil when it is not a DAT session error
    /// (Gateway, cancellation, adapter errors keep their own handling).
    public init?(classifying error: any Error) {
        guard let error = error as? DeviceSessionError else { return nil }
        self.init(error)
    }

    /// What the host should do about it.
    public var response: MetaDATSessionErrorResponse {
        switch self {
        // Meta: "Not blocking. The session can continue" (Version
        // Dependencies, "Handling version errors at runtime").
        case .dwaOutOfStuRange: return .continueSession
        case .thermalCritical, .thermalEmergency, .peakPowerShutdown: return .coolDown
        case .batteryCritical: return .waitForCharge
        // Meta: update via App Connections in the Meta AI app.
        case .datAppOnTheGlassesUpdateRequired: return .updateGlassesApp
        // Meta: the glasses-side integration did not launch or is not
        // installed; verify the glasses setup in the Meta AI app first.
        case .dwaUnavailable: return .updateGlassesApp
        // Meta: terminal; only a new app build helps.
        case .insufficientSDKVersion: return .updateCompanionApp
        case .noEligibleDevice, .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle,
             .capabilityAlreadyActive, .capabilityNotFound, .unexpectedError:
            return .reconnect
        }
    }
}

public enum MetaDATSessionErrorResponse: Equatable, Sendable {
    /// Log only; the session keeps running.
    case continueSession
    /// The session is over: reconnect as usual (backoff).
    case reconnect
    /// Overheated or a power peak: stop, wait until the glasses cool down.
    case coolDown
    /// Battery critical: wait until charging or the level rises.
    case waitForCharge
    /// The DAT app on the glasses needs an update or setup in Meta AI.
    case updateGlassesApp
    /// This app's SDK is too old for the glasses: a new app build is needed.
    case updateCompanionApp

    /// Whether the session error ends the device session for the host.
    public var endsSession: Bool { self != .continueSession }
}
