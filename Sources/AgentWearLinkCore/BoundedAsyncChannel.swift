import Foundation

/// A small bounded async channel used at streaming boundaries.
///
/// When full, the oldest buffered value is dropped. Media transports may use
/// stricter policies; text/control streams should choose capacity deliberately.
///
/// Suspended consumers are cancellation-aware: cancelling a task waiting in
/// `next()` removes and resumes its continuation instead of retaining it.
public actor BoundedAsyncChannel<Element: Sendable> {
    public let capacity: Int

    private var buffer: [Element] = []
    private var waiters: [UUID: CheckedContinuation<Element?, Never>] = [:]
    private var waiterOrder: [UUID] = []
    private var finished = false

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func send(_ value: Element) {
        guard !finished else { return }

        if let waiter = takeNextWaiter() {
            waiter.resume(returning: value)
            return
        }

        if buffer.count == capacity {
            buffer.removeFirst()
        }
        buffer.append(value)
    }

    public func next() async -> Element? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if finished || Task.isCancelled {
            return nil
        }

        let waiterID = UUID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[waiterID] = continuation
                waiterOrder.append(waiterID)
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        buffer.removeAll(keepingCapacity: false)

        let pending = waiterOrder.compactMap { waiters[$0] }
        waiters.removeAll(keepingCapacity: false)
        waiterOrder.removeAll(keepingCapacity: false)

        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    private func takeNextWaiter() -> CheckedContinuation<Element?, Never>? {
        while !waiterOrder.isEmpty {
            let id = waiterOrder.removeFirst()
            if let waiter = waiters.removeValue(forKey: id) {
                return waiter
            }
        }
        return nil
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        waiter.resume(returning: nil)
    }
}
