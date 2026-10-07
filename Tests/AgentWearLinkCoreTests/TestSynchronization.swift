import Foundation

enum TestSynchronizationError: Error, Sendable, Equatable {
    case timedOut(String)
}

actor TestCountSignal {
    private struct Waiter {
        let target: Int
        let label: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func increment(by amount: Int = 1) {
        precondition(amount > 0)
        count += amount

        let ready = waiters.filter { count >= $0.value.target }
        for (id, waiter) in ready {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func current() -> Int { count }

    func wait(
        until target: Int,
        timeout: Duration = .seconds(1),
        label: String
    ) async throws {
        precondition(target >= 0)
        guard count < target else { return }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(
                    target: target,
                    label: label,
                    continuation: continuation
                )

                Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.expire(id)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(
            throwing: TestSynchronizationError.timedOut(waiter.label)
        )
    }

    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

func waitUntilTestCondition(
    _ label: String,
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while !(await condition()) {
        guard clock.now < deadline else {
            throw TestSynchronizationError.timedOut(label)
        }
        await Task.yield()
    }
}
