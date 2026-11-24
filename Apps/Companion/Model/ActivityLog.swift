import Foundation

/// Bounded on-device activity log for the hidden diagnostics view. It holds
/// lifecycle notes only; callers must not pass tokens or transcripts.
public struct ActivityLog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        public let message: String
    }

    public private(set) var entries: [Entry] = []
    public let capacity: Int
    private var nextID = 0

    public init(capacity: Int = 300) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ message: String, at date: Date = Date()) {
        entries.append(Entry(id: nextID, date: date, message: message))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Plain text for the copy action, oldest first.
    public func export(formatter: (Date) -> String) -> String {
        entries.map { "\(formatter($0.date)) \($0.message)" }.joined(separator: "\n")
    }
}
