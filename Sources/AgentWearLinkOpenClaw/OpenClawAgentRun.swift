import Foundation

public struct OpenClawAgentParams: Encodable, Sendable {
    public let message: String
    public let sessionKey: String?
    public let idempotencyKey: String

    public init(
        message: String,
        sessionKey: String? = nil,
        idempotencyKey: String
    ) {
        self.message = message
        self.sessionKey = sessionKey
        self.idempotencyKey = idempotencyKey
    }
}

public struct OpenClawAgentAccepted: Decodable, Sendable, Equatable {
    public let runId: String
    public let acceptedAt: Int64
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
}

public struct OpenClawSessionAbortParams: Encodable, Sendable {
    public let runId: String

    public init(runId: String) {
        self.runId = runId
    }
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
