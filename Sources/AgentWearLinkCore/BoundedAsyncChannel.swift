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

    // Fixed-size ring buffer: enqueue/dequeue/drop-oldest are O(1).
    private var buffer: [Element?]
    private var bufferHead = 0
    private var bufferCount = 0

    // Waiters use a FIFO id queue plus a dictionary. Cancellation removes the
    // continuation from the dictionary in O(1); stale ids are skipped lazily.
    private var waiters: [UUID: CheckedContinuation<Element?, Never>] = [:]
    private var waiterOrder: [UUID] = []
    private var waiterHead = 0

    private var finished = false

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = Array(repeating: nil, count: capacity)
    }

    public func send(_ value: Element) {
        guard !finished else { return }

        if let waiter = takeNextWaiter() {
            waiter.resume(returning: value)
            return
        }

        if bufferCount == capacity {
            // Overwrite the oldest slot, then advance the head.
            buffer[bufferHead] = value
            bufferHead = (bufferHead + 1) % capacity
            return
        }

        let tail = (bufferHead + bufferCount) % capacity
        buffer[tail] = value
        bufferCount += 1
    }

    public func next() async -> Element? {
        if bufferCount > 0 {
            let value = buffer[bufferHead]
            buffer[bufferHead] = nil
            bufferHead = (bufferHead + 1) % capacity
            bufferCount -= 1
            if bufferCount == 0 {
                bufferHead = 0
            }
            return value
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
        clearBuffer()

        let pending = waiterOrder[waiterHead...].compactMap { waiters[$0] }
        waiters.removeAll(keepingCapacity: false)
        waiterOrder.removeAll(keepingCapacity: false)
        waiterHead = 0

        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }

    private func takeNextWaiter() -> CheckedContinuation<Element?, Never>? {
        while waiterHead < waiterOrder.count {
            let id = waiterOrder[waiterHead]
            waiterHead += 1

            if let waiter = waiters.removeValue(forKey: id) {
                compactWaiterOrderIfNeeded()
                return waiter
            }
        }

        resetWaiterOrderIfDrained()
        return nil
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: nil)

        if waiters.isEmpty {
            waiterOrder.removeAll(keepingCapacity: true)
            waiterHead = 0
        } else {
            compactWaiterOrderIfNeeded()
        }
    }

    private func compactWaiterOrderIfNeeded() {
        let queued = waiterOrder.count - waiterHead

        // Compact only when stale ids materially dominate the live queue.
        // The occasional O(n) copy keeps aggregate queue operations amortized O(1).
        guard waiterHead >= 64 || queued > waiters.count * 2 + 32 else {
            return
        }

        waiterOrder = waiterOrder[waiterHead...].filter {
            waiters[$0] != nil
        }
        waiterHead = 0
    }

    private func resetWaiterOrderIfDrained() {
        guard waiterHead == waiterOrder.count else { return }
        waiterOrder.removeAll(keepingCapacity: true)
        waiterHead = 0
    }

    private func clearBuffer() {
        for index in buffer.indices {
            buffer[index] = nil
        }
        bufferHead = 0
        bufferCount = 0
    }
}
