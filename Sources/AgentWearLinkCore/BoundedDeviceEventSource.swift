import Foundation

/// Bounded single-consumer device control/text delivery. A lost control event
/// invalidates the whole subscription, not just the producer's interaction.
public final class BoundedDeviceEventSource: @unchecked Sendable {
    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var queue: [InteractionEvent] = []
        private var waiter: CheckedContinuation<InteractionEvent?, Never>?
        private var closed = false

        init(limit: Int) { self.limit = limit }

        func offer(_ event: InteractionEvent) {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: event)
                return
            }
            if queue.count == limit {
                // No queued prefix/suffix from a known-incomplete sequence may
                // reach Core. Store exactly one generation-wide terminal failure.
                queue = [.failed(nil, .overloaded("Device event stream buffer capacity exceeded"))]
                closed = true
            } else {
                queue.append(event)
            }
            lock.unlock()
        }

        func next() async -> InteractionEvent? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if Task.isCancelled || waiter != nil {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else if !queue.isEmpty {
                        let event = queue.removeFirst()
                        lock.unlock()
                        continuation.resume(returning: event)
                    } else if closed {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else {
                        waiter = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                self.finish()
            }
        }

        func finish() {
            lock.lock()
            closed = true
            queue.removeAll(keepingCapacity: false)
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(returning: nil)
        }
    }

    private let lock = NSLock()
    private let bufferLimit: Int
    private var nextGeneration: UInt64 = 0
    private var subscription: (generation: UInt64, mailbox: Mailbox)?

    public init(bufferLimit: Int) {
        precondition(bufferLimit > 0)
        self.bufferLimit = bufferLimit
    }

    public func stream() -> AsyncStream<InteractionEvent> {
        let mailbox = Mailbox(limit: bufferLimit)
        lock.withLock {
            subscription?.mailbox.finish()
            nextGeneration &+= 1
            subscription = (nextGeneration, mailbox)
        }
        return AsyncStream(unfolding: { await mailbox.next() }, onCancel: { mailbox.finish() })
    }

    public func currentGeneration() -> UInt64? {
        lock.withLock { subscription?.generation }
    }

    public func yield(_ event: InteractionEvent) {
        lock.withLock { subscription?.mailbox.offer(event) }
    }

    /// Use when a producer owns a particular connection generation.
    public func yield(_ event: InteractionEvent, generation: UInt64?) {
        guard let generation else { return }
        lock.withLock {
            guard subscription?.generation == generation else { return }
            subscription?.mailbox.offer(event)
        }
    }

    public func finish(generation: UInt64?) {
        guard let generation else { return }
        lock.withLock {
            guard subscription?.generation == generation else { return }
            subscription?.mailbox.finish()
            subscription = nil
        }
    }

    public func finish() {
        lock.withLock {
            subscription?.mailbox.finish()
            subscription = nil
        }
    }
}
