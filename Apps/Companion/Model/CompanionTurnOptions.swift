import AgentWearLinkOpenClaw
import Foundation

/// Per-turn options sent with every glasses request.
public enum CompanionTurnOptions {
    /// Lets Gateway plugins recognise a spoken glasses turn
    /// (`inputProvenance.sourceChannel`).
    public static let inputSourceChannel = "agentwearlink"

    public static let voiceStylePrompt = """
    이 요청은 사용자가 스마트 안경으로 말한 것이고, 답은 음성으로 읽힙니다. \
    두세 문장 이내로 짧게, 말하듯이 답하세요. 마크다운, 목록, 표, 링크, 이모지는 쓰지 마세요.
    """

    public static func make(from settings: CompanionSettings) -> OpenClawAgentTurnOptions {
        make(
            telegramChatID: settings.telegramEnabled ? settings.telegramChatID : "",
            voiceStyle: settings.voiceStyle
        )
    }

    /// - Parameters:
    ///   - telegramChatID: when valid, the Gateway also posts the final reply
    ///     to this Telegram chat. Empty or non-numeric turns delivery off.
    ///   - voiceStyle: asks the agent for a short, speakable answer.
    public static func make(
        telegramChatID: String,
        telegramAccountID: String = "default",
        voiceStyle: Bool
    ) -> OpenClawAgentTurnOptions {
        let chatID = telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenClawAgentTurnOptions(
            replyDelivery: isTelegramChatID(chatID)
                ? .init(channel: "telegram", to: chatID, accountId: telegramAccountID)
                : nil,
            extraSystemPrompt: voiceStyle ? voiceStylePrompt : nil,
            inputSourceChannel: inputSourceChannel
        )
    }

    /// A Telegram chat id is an optionally negative decimal integer.
    public static func isTelegramChatID(_ raw: String) -> Bool {
        let chatID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = chatID.hasPrefix("-") ? chatID.dropFirst() : Substring(chatID)
        return !digits.isEmpty && digits.count <= 20
            && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
