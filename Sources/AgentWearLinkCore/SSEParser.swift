import Foundation

public struct ServerSentEvent: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retryMilliseconds: Int?

    public init(id: String? = nil, event: String? = nil, data: String = "", retryMilliseconds: Int? = nil) {
        self.id = id
        self.event = event
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }
}

public enum SSEParserError: Error, Sendable, Equatable {
    case pendingEventTooLarge(actual: Int, maximum: Int)
}

/// Incremental UTF-8 SSE parser with a strict bound on incomplete event state.
/// CRLF, LF and CR are accepted; one leading UTF-8 BOM is ignored.
public struct SSEParser: Sendable {
    public let maximumBufferedBytes: Int

    private var lineBuffer = Data()
    private var skipLeadingLF = false
    private var isFirstLine = true
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
        var events: [ServerSentEvent] = []

        for byte in bytes {
            if skipLeadingLF {
                skipLeadingLF = false
                if byte == 0x0A { continue }
            }

            switch byte {
            case 0x0D:
                try processCurrentLine(into: &events)
                skipLeadingLF = true
            case 0x0A:
                try processCurrentLine(into: &events)
            default:
                lineBuffer.append(byte)
                try validatePendingSize()
            }
        }
        return events
    }

    private mutating func processCurrentLine(into events: inout [ServerSentEvent]) throws {
        pendingEventBytes += lineBuffer.count + 1
        try validatePendingSize()

        var line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)

        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }

        if line.isEmpty {
            if !dataLines.isEmpty {
                events.append(ServerSentEvent(
                    id: currentID,
                    event: currentEvent,
                    data: dataLines.joined(separator: "\n"),
                    retryMilliseconds: currentRetry
                ))
            }
            currentEvent = nil
            dataLines.removeAll(keepingCapacity: true)
            currentRetry = nil
            pendingEventBytes = 0
            return
        }

        if line.hasPrefix(":") { return }

        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
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

    private mutating func validatePendingSize() throws {
        let actual = pendingEventBytes + lineBuffer.count
        guard actual <= maximumBufferedBytes else {
            resetAfterLimitViolation()
            throw SSEParserError.pendingEventTooLarge(actual: actual, maximum: maximumBufferedBytes)
        }
    }

    private mutating func resetAfterLimitViolation() {
        lineBuffer.removeAll(keepingCapacity: false)
        skipLeadingLF = false
        isFirstLine = true
        currentID = nil
        currentEvent = nil
        dataLines.removeAll(keepingCapacity: false)
        currentRetry = nil
        pendingEventBytes = 0
    }
}
