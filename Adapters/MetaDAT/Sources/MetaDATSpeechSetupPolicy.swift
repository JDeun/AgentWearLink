import AgentWearLinkCore
import Foundation

/// DAT Speech can be unavailable independently from the camera session.
/// Only explicit capability unavailability is nonfatal; cancellation,
/// registration/device-session failures and unexpected errors remain fatal.
enum MetaDATSpeechSetupPolicy {
    static func mayContinueWithoutSpeech(_ error: Error) -> Bool {
        guard let failure = error as? AWLError else { return false }
        if case .capabilityUnavailable = failure {
            return true
        }
        return false
    }
}
