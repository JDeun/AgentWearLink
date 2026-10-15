import Foundation

/// Silent recovery: wait for the glasses, settle, then reconnect with the
/// stored grant, backing off on repeated failures. Never notifies the user.
public enum RecoveryPolicy {
    /// A new DAT session too soon after a stop fails (dat-ios #231).
    public static let settleDelay: TimeInterval = 2
    public static let backoff: [TimeInterval] = [5, 10, 30, 60]

    public static func delay(afterFailedAttempt attempt: Int) -> TimeInterval {
        backoff[min(max(attempt, 0), backoff.count - 1)]
    }
}
