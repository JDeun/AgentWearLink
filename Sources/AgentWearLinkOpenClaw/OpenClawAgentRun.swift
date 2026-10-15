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

/// Per-turn Gateway options a host applies to every submitted turn.
/// The defaults leave the wire request unchanged.
public struct OpenClawAgentTurnOptions: Sendable, Equatable {
    /// Asks the Gateway to also deliver the final reply to a channel
    /// conversation, so a voice turn leaves a record where the user
    /// normally reads the agent (for example a Telegram DM).
    public struct ReplyDelivery: Sendable, Equatable {
        public let channel: String
        public let to: String
        public let accountId: String?

        public init(channel: String, to: String, accountId: String? = nil) {
            self.channel = channel
            self.to = to
            self.accountId = accountId
        }
    }

    public let replyDelivery: ReplyDelivery?
    /// Appended to the agent's system prompt for this turn only, e.g. to
    /// keep a spoken answer short and free of markdown.
    public let extraSystemPrompt: String?
    /// Tags the turn as user input that arrived through this host, e.g.
    /// "agentwearlink", so Gateway plugins can tell a spoken turn from a
    /// typed one (sent as inputProvenance.sourceChannel).
    public let inputSourceChannel: String?

    public init(
        replyDelivery: ReplyDelivery? = nil,
        extraSystemPrompt: String? = nil,
        inputSourceChannel: String? = nil
    ) {
        self.replyDelivery = replyDelivery
        self.extraSystemPrompt = extraSystemPrompt
        self.inputSourceChannel = inputSourceChannel
    }

    /// The same options with `hint` appended to the extra system prompt
    /// (blank-line separated), e.g. a per-turn note that a photo is attached.
    public func appendingSystemPrompt(_ hint: String?) -> OpenClawAgentTurnOptions {
        let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return self }
        let combined = extraSystemPrompt.map { $0.isEmpty ? trimmed : $0 + "\n\n" + trimmed } ?? trimmed
        return OpenClawAgentTurnOptions(
            replyDelivery: replyDelivery,
            extraSystemPrompt: combined,
            inputSourceChannel: inputSourceChannel
        )
    }
}

public struct OpenClawInputProvenance: Encodable, Sendable, Equatable {
    public let kind: String
    public let sourceChannel: String?

    public static func externalUser(sourceChannel: String) -> Self {
        Self(kind: "external_user", sourceChannel: sourceChannel)
    }
}

public struct OpenClawAgentParams: Encodable, Sendable {
    public let message: String
    public let sessionKey: String?
    public let idempotencyKey: String
    public let attachments: [OpenClawAgentAttachment]?
    public let deliver: Bool?
    public let channel: String?
    public let to: String?
    public let accountId: String?
    public let extraSystemPrompt: String?
    public let inputProvenance: OpenClawInputProvenance?

    public init(
        message: String,
        sessionKey: String? = nil,
        idempotencyKey: String,
        attachments: [OpenClawAgentAttachment]? = nil,
        turnOptions: OpenClawAgentTurnOptions = .init()
    ) {
        self.message = message
        self.sessionKey = sessionKey
        self.idempotencyKey = idempotencyKey
        self.attachments = attachments
        let delivery = turnOptions.replyDelivery
        self.deliver = delivery == nil ? nil : true
        self.channel = delivery?.channel
        self.to = delivery?.to
        self.accountId = delivery?.accountId
        self.extraSystemPrompt = turnOptions.extraSystemPrompt
        self.inputProvenance = turnOptions.inputSourceChannel.map {
            .externalUser(sourceChannel: $0)
        }
    }
}

public struct OpenClawAgentAccepted: Decodable, Sendable, Equatable {
    public let runId: String
    public let acceptedAt: Int64
    public let status: String?
    public let sessionKey: String?
    public let agentId: String?
}

public struct OpenClawAgentIdentityParams: Encodable, Sendable {
    public let agentId: String?
    public let sessionKey: String?

    public init(agentId: String? = nil, sessionKey: String? = nil) {
        self.agentId = agentId
        self.sessionKey = sessionKey
    }
}

/// The agent's public display identity (`agent.identity.get`). Hosts show
/// this instead of hardcoding an agent name; OpenClaw resolves it from
/// config or the workspace identity file.
public struct OpenClawAgentIdentity: Decodable, Sendable, Equatable {
    public let agentId: String
    public let name: String?
    public let avatar: String?

    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? agentId : trimmed
    }
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

public struct OpenClawTTSSpeakParams: Encodable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// One rendered sentence from `tts.speak`.
public struct OpenClawSpeechClip: Decodable, Sendable, Equatable {
    public let audioBase64: String
    public let provider: String
    public let outputFormat: String?
    public let mimeType: String?
    public let fileExtension: String?

    public var audio: Data? { Data(base64Encoded: audioBase64) }
}
