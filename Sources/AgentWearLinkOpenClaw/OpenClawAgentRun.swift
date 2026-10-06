import Foundation

public struct OpenClawAgentParams: Encodable, Sendable {
    public let message: String
    public let agentId: String?
    public let sessionKey: String?
    public let deliver: Bool?
    public let idempotencyKey: String

    public init(
        message: String,
        agentId: String? = nil,
        sessionKey: String? = nil,
        deliver: Bool? = nil,
        idempotencyKey: String
    ) {
        self.message = message
        self.agentId = agentId
        self.sessionKey = sessionKey
        self.deliver = deliver
        self.idempotencyKey = idempotencyKey
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
    public let runId: String
    public let status: String
    public let startedAt: Int64?
    public let endedAt: Int64?
    public let error: String?
    public let stopReason: String?
    public let timeoutPhase: String?
    public let providerStarted: Bool?
    public let terminalReply: JSONValue?
    public let terminalReceipt: JSONValue?
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
