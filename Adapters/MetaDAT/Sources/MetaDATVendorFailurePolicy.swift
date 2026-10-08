import Foundation

/// Converts untrusted Meta SDK failures to stable, non-sensitive user-facing
/// categories. SDK Error/LocalizedError descriptions may contain device IDs,
/// account context, local addresses, or diagnostic payload fragments.
enum MetaDATVendorFailurePolicy {
    enum Surface: Sendable {
        case session
        case speech
    }

    static func message(for _: any Error, surface: Surface) -> String {
        switch surface {
        case .session:
            return "Meta DAT device session error (details redacted)"
        case .speech:
            return "Meta DAT Speech error (details redacted)"
        }
    }
}
