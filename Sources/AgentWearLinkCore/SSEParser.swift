import Foundation

public struct ServerSentEvent: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retryMilliseconds: Int?

    public init(
        id: String? = nil,
        event: String? = nil,
        data: String = "",
        retryMilliseconds: Int? = nil
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }
}

public enum SSEParserError: Error, Sendable, Equatable {
    case pendingEventTooLarge(actual: Int, maximum: Int)
}

/// Incremental UTF-8 SSE parser.
///
/// The parser is transport-only: it does not interpret agent-specific event
/// names or JSON payloads. Pending partial/event data is strictly bounded so a
/// peer cannot grow memory indefinitely by withholding an SSE event terminator.
public struct SSEParser: Sendable {
    public let maximumBufferedBytes: Int

    private var buffer = Data()
    private var currentID: String?
    private var currentEvent: String?
    private var dataLines: [String] = []
    private var currentRetry: Int?
    private var pendingEventBytes = 0

    public init(maximumBufferedBytes: Int = 1_048_576) {
        precondition(maximumBufferedBytes > 0)
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    public mutating func append(_ bytes: Data) throws -> [ServerSentEvent] {
        buffer.append(bytes)
        var events: [ServerSentEvent] = []

        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer[..<range.lowerBound]
            buffer.removeSubrange(...range.lowerBound)

            guard var line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            if line.last == "\r" { line.removeLast() }

            if line.isEmpty {
                if !dataLines.isEmpty {
                    events.append(
                        ServerSentEvent(
                            id: currentID,
                            event: currentEvent,
                            data: dataLines.joined(separator: "\n"),
                            retryMilliseconds: currentRetry
                        )
                    )
                }
                currentEvent = nil
                dataLines.removeAll(keepingCapacity: true)
                currentRetry = nil
                pendingEventBytes = 0
                continue
            }

            pendingEventBytes += lineData.count + 1
            try validatePendingSize(bufferBytes: buffer.count)

            if line.hasPrefix(":") { continue }

            let pieces = line.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let field = String(pieces[0])
            var value = pieces.count > 1 ? String(pieces[1]) : ""
            if value.first == " " { value.removeFirst() }

            switch field {
            case "id":
                if !value.contains("\0") { currentID = value }
            case "event":
                currentEvent = value
            case "data":
                dataLines.append(value)
            case "retry":
                currentRetry = Int(value)
            default:
                break
            }
        }

        try validatePendingSize(bufferBytes: buffer.count)
        return events
    }

    private mutating func validatePendingSize(bufferBytes: Int) throws {
        let actual = pendingEventBytes + bufferBytes
        guard actual <= maximumBufferedBytes else {
            resetAfterLimitViolation()
            throw SSEParserError.pendingEventTooLarge(
                actual: actual,
                maximum: maximumBufferedBytes
            )
        }
    }

    private mutating func resetAfterLimitViolation() {
        buffer.removeAll(keepingCapacity: false)
        currentID = nil
        currentEvent = nil
        dataLines.removeAll(keepingCapacity: false)
        currentRetry = nil
        pendingEventBytes = 0
    }
}
