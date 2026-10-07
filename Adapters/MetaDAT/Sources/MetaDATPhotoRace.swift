import Foundation

public enum MetaDATPhotoRaceError: Error, Sendable, Equatable {
    case timeout
}

private final class MetaDATTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private var fired = false

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func cancel() {
        let shouldRun = lock.withLock { () -> Bool in
            guard !fired else { return false }
            fired = true
            return true
        }
        if shouldRun {
            action()
        }
    }
}

/// Races one transfer task against a timeout.
///
/// Task cancellation alone is not sufficient for vendor awaitables that do not
/// cooperatively observe Swift cancellation. The cancelTransfer closure owns
/// source-level teardown and is fired exactly once on deadline or caller
/// cancellation before the task-group scope is allowed to unwind.
public enum MetaDATPhotoRace {
    public static func run(
        timeout: Duration,
        cancelTransfer: @escaping @Sendable () -> Void = {},
        transfer: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let sourceCancellation = MetaDATTransferCancellation(
            action: cancelTransfer
        )

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await transfer()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    try Task.checkCancellation()
                    throw MetaDATPhotoRaceError.timeout
                }

                do {
                    guard let first = try await group.next() else {
                        sourceCancellation.cancel()
                        group.cancelAll()
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                } catch {
                    sourceCancellation.cancel()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            sourceCancellation.cancel()
        }
    }
}
