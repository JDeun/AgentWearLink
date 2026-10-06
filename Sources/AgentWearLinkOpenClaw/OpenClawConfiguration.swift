import Foundation

public struct OpenClawConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    public let bearerToken: String
    public let model: String
    public let conversationID: String
    public let sessionKey: String?
    public let messageChannel: String?
    public let timeout: TimeInterval
    public let maximumEventBytes: Int

    public init(
        baseURL: URL,
        bearerToken: String,
        model: String = "openclaw/default",
        conversationID: String,
        sessionKey: String? = nil,
        messageChannel: String? = nil,
        timeout: TimeInterval = 120,
        maximumEventBytes: Int = 262_144
    ) {
        precondition(!bearerToken.isEmpty)
        precondition(!conversationID.isEmpty)
        precondition(maximumEventBytes > 0)

        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.model = model
        self.conversationID = conversationID
        self.sessionKey = sessionKey
        self.messageChannel = messageChannel
        self.timeout = timeout
        self.maximumEventBytes = maximumEventBytes
    }

    public var description: String {
        let sessionKeyDescription = sessionKey == nil ? "nil" : "<redacted>"
        let messageChannelDescription = messageChannel == nil ? "nil" : "<redacted>"

        return "OpenClawConfiguration(baseURL: \(baseURL), bearerToken: <redacted>, model: \(model), conversationID: <redacted>, sessionKey: \(sessionKeyDescription), messageChannel: \(messageChannelDescription), timeout: \(timeout), maximumEventBytes: \(maximumEventBytes))"
    }

    public var debugDescription: String { description }
}
