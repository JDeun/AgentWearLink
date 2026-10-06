import Foundation

/// A small bounded async channel used at streaming boundaries.
///
/// When full, the oldest buffered value is dropped. Media transports may use
/// stricter policies; text/control streams should choose capacity deliberately.
public actor BoundedAsyncChannel<Element: Sendable> {
    public let capacity: Int

    private var buffer: [Element] = []
    private var waiters: [CheckedContinuation<Element?, Never>] = []
    private var finished = false

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func send(_ value: Element) {
        guard !finished else { return }

        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
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
        if finished { return nil }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        buffer.removeAll(keepingCapacity: false)
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: nil)
        }
    }
}
