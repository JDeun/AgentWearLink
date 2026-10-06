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
///
/// WHATWG event streams permit CRLF, LF, or CR line endings. UTF-8 decoding
/// uses replacement semantics and one leading BOM is ignored. An incomplete
/// event is intentionally not dispatched until a blank line is observed.
public struct SSEParser: Sendable {
    private var lineBuffer = Data()
    private var skipLeadingLF = false
    private var isFirstLine = true

    private var currentID: String?
    private var currentEvent: String?
    private var dataLines: [String] = []
    private var currentRetry: Int?

    public init() {}

    public mutating func append(_ bytes: Data) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []

        for byte in bytes {
            if skipLeadingLF {
                skipLeadingLF = false
                if byte == 0x0A {
                    continue
                }
            }

            switch byte {
            case 0x0D:
                processCurrentLine(into: &events)
                skipLeadingLF = true

            case 0x0A:
                processCurrentLine(into: &events)

            default:
                lineBuffer.append(byte)
            }
        }

        return events
    }

    private mutating func processCurrentLine(
        into events: inout [ServerSentEvent]
    ) {
        var line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)

        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" {
                line.removeFirst()
            }
        }

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
            return
        }

        if line.hasPrefix(":") {
            return
        }

        let pieces = line.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let field = String(pieces[0])
        var value = pieces.count > 1 ? String(pieces[1]) : ""
        if value.first == " " {
            value.removeFirst()
        }

        switch field {
        case "id":
            if !value.contains("\0") {
                currentID = value
            }

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
}
