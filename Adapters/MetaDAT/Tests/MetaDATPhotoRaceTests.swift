import Foundation
import XCTest
@testable import AgentWearLinkMetaDATIntegration

private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock {
            count += 1
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class CancellationInsensitivePhotoTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []
    private var armed = false
    private var cancellations = 0

    func transfer() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                self.continuation = continuation
                armed = true
                defer { armedWaiters.removeAll() }
                return armedWaiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilArmed() async {
        let alreadyArmed = lock.withLock { armed }
        if alreadyArmed { return }

        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if armed {
                    return true
                }
                armedWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func cancel() {
        let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            cancellations += 1
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(throwing: CancellationError())
    }

    func cancellationCount() -> Int {
        lock.withLock { cancellations }
    }
}

final class MetaDATPhotoRaceTests: XCTestCase {
    func testTimeoutActivelyCancelsCancellationInsensitiveTransfer() async {
        let source = CancellationInsensitivePhotoTransfer()

        let task = Task {
            try await MetaDATPhotoRace.run(
                timeout: .milliseconds(20),
                cancelTransfer: {
                    source.cancel()
                },
                transfer: {
                    try await source.transfer()
                }
            )
        }

        await source.waitUntilArmed()

        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch let error as MetaDATPhotoRaceError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(source.cancellationCount(), 1)
    }

    func testCallerCancellationActivelyCancelsTransferExactlyOnce() async {
        let source = CancellationInsensitivePhotoTransfer()

        let task = Task {
            try await MetaDATPhotoRace.run(
                timeout: .seconds(30),
                cancelTransfer: {
                    source.cancel()
                },
                transfer: {
                    try await source.transfer()
                }
            )
        }

        await source.waitUntilArmed()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(source.cancellationCount(), 1)
    }

    func testSuccessfulTransferDoesNotCancelSource() async throws {
        let data = Data([1, 2, 3])
        let cancellationCounter = CancellationCounter()

        let result = try await MetaDATPhotoRace.run(
            timeout: .seconds(1),
            cancelTransfer: {
                cancellationCounter.increment()
            },
            transfer: {
                data
            }
        )

        XCTAssertEqual(result, data)
        XCTAssertEqual(cancellationCounter.value, 0)
    }
}
