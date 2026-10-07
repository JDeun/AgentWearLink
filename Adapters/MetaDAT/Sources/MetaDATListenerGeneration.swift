import Foundation

/// Synchronous generation gate for SDK listener callbacks.
///
/// Invalidation happens before asynchronous token cancellation, so callbacks from
/// a retired listener are rejected immediately even if the vendor token has not
/// finished cancelling yet.
final class MetaDATListenerGeneration: @unchecked Sendable {
    typealias Token = UInt64

    private let lock = NSLock()
    private var current: Token = 0

    func begin() -> Token {
        lock.withLock {
            current &+= 1
            return current
        }
    }

    func invalidate() {
        lock.withLock {
            current &+= 1
        }
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.withLock { current == token }
    }
}
