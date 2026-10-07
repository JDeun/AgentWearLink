import Foundation

/// One private-media attachment for the native OpenClaw `agent` request.
///
/// `Data` is encoded by Foundation as a base64 JSON string, matching the
/// Gateway's `attachments[].content` contract without retaining a second
/// long-lived base64 copy in the model.
public struct OpenClawAgentAttachment: Encodable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let mimeType: String
    public let fileName: String
    public let content: Data

    public init(mimeType: String, fileName: String, content: Data) {
        self.mimeType = mimeType
        self.fileName = fileName
        self.content = content
    }

    public var rawByteCount: Int {
        content.count
    }

    /// Exact base64 payload length before JSON/string allocation.
    public var base64EncodedByteCount: Int {
        let completeTriples = content.count / 3
        let remainder = content.count % 3
        let (scaled, scaleOverflow) = completeTriples.multipliedReportingOverflow(by: 4)
        guard !scaleOverflow else { return Int.max }
        let paddingBytes = remainder == 0 ? 0 : 4
        let (total, addOverflow) = scaled.addingReportingOverflow(paddingBytes)
        return addOverflow ? Int.max : total
    }

    public var description: String {
        "OpenClawAgentAttachment(mimeType: \(mimeType), fileName: \(fileName), contentBytes: \(content.count))"
    }

    public var debugDescription: String { description }
}

public struct OpenClawAgentParams: Encodable, Sendable {
    public let message: String
    public let sessionKey: String?
    public let idempotencyKey: String
    public let attachments: [OpenClawAgentAttachment]?

    public init(
        message: String,
        sessionKey: String? = nil,
        idempotencyKey: String,
        attachments: [OpenClawAgentAttachment]? = nil
    ) {
        self.message = message
        self.sessionKey = sessionKey
        self.idempotencyKey = idempotencyKey
        self.attachments = attachments
    }
}

public struct OpenClawAgentAccepted: Decodable, Sendable, Equatable {
    public let runId: String
    public let acceptedAt: Int64
    public let status: String?
    public let sessionKey: String?
    public let agentId: String?
}

public struct OpenClawAgentWaitParams: Encodable, Sendable {
    public let runId: String
    public let timeoutMs: Int?

    public init(runId: String, timeoutMs: Int? = nil) {
        self.runId = runId
        self.timeoutMs = timeoutMs
    }
}

public struct OpenClawAgentWaitResult: Decodable, Sendable, Equatable {
    public let status: String
    public let error: String?
    public let retryableTransportError: Bool?
    public let startedAt: Int64?
    public let endedAt: Int64?
    public let stopReason: String?
    public let livenessState: String?
    public let yielded: Bool?
    public let pendingError: Bool?
    public let timeoutPhase: String?
    public let providerStarted: Bool?
    public let terminalReply: JSONValue?
    public let sourceReplyDelivered: Bool?
}

public struct OpenClawChatAbortParams: Encodable, Sendable {
    public let sessionKey: String
    public let runId: String
    public let agentId: String?

    public init(
        sessionKey: String,
        runId: String,
        agentId: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.runId = runId
        self.agentId = agentId
    }
}

public struct OpenClawChatAbortResult: Decodable, Sendable, Equatable {
    public let aborted: Bool
    public let runIds: [String]?
}

public struct OpenClawAgentEvent: Decodable, Sendable, Equatable {
    public let runId: String
    public let stream: String
    public let data: JSONValue?
    public let seq: Int?
}

public enum OpenClawAgentRunUpdate: Sendable, Equatable {
    case assistant(runID: String, payload: JSONValue?)
    case tool(runID: String, payload: JSONValue?)
    case lifecycle(runID: String, payload: JSONValue?)
}
