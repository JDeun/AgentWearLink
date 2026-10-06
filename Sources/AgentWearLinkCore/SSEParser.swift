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

/// Incremental UTF-8 SSE parser.
///
/// The parser is transport-only: it does not interpret agent-specific event
/// names or JSON payloads.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var currentID: String?
    private var currentEvent: String?
    private var dataLines: [String] = []
    private var currentRetry: Int?

    public init() {}

    public mutating func append(_ bytes: Data) -> [ServerSentEvent] {
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
                continue
            }

            if line.hasPrefix(":") { continue }

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

        return events
    }
}
