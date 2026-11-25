import Foundation

struct LabStreamSignals: OptionSet, Equatable {
    let rawValue: UInt8
    static let ready = Self(rawValue: 1)
    static let end = Self(rawValue: 2)
    static let error = Self(rawValue: 4)
}

/// Single-owner event mailbox: one scheduled drain, no event queue allocation,
/// union signals instead of reentering I/O. Retire fences every pending drain.
struct LabStreamEvents {
    private var generation: UUID?
    private var pending: LabStreamSignals = []

    mutating func begin(generation: UUID) {
        self.generation = generation
        pending = []
    }

    mutating func retire() {
        generation = nil
        pending = []
    }

    /// True means the caller must queue one deferred drain.
    mutating func enqueue(generation token: UUID, signals: LabStreamSignals) -> Bool {
        guard generation == token, !signals.isEmpty else { return false }
        let schedule = pending.isEmpty
        pending.formUnion(signals)
        return schedule
    }

    mutating func take(generation token: UUID) -> LabStreamSignals? {
        guard generation == token, !pending.isEmpty else { return nil }
        let batch = pending
        pending = []
        return batch
    }
}
