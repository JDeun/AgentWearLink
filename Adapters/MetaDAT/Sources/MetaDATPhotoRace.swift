import Foundation

public enum MetaDATPhotoRaceError: Error, Sendable, Equatable { case timeout }

/// Races one transfer task against a timeout. Structured cancellation guarantees
/// the losing branch is cancelled; the caller owns cancellation of the transfer source.
public enum MetaDATPhotoRace {
    public static func run(
        timeout: Duration,
        transfer: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await transfer() }
            group.addTask {
                try await Task.sleep(for: timeout)
                try Task.checkCancellation()
                throw MetaDATPhotoRaceError.timeout
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
