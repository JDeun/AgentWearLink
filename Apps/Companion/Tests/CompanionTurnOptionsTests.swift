import AgentWearLinkOpenClaw
import XCTest

final class CompanionTurnOptionsTests: XCTestCase {
    func testAlwaysTagsTheInputSource() {
        let options = CompanionTurnOptions.make(telegramChatID: "", voiceStyle: false)
        XCTAssertEqual(options.inputSourceChannel, "agentwearlink")
        XCTAssertNil(options.replyDelivery)
        XCTAssertNil(options.extraSystemPrompt)
    }

    func testVoiceStyleAddsPrompt() {
        let options = CompanionTurnOptions.make(telegramChatID: "", voiceStyle: true)
        XCTAssertEqual(options.extraSystemPrompt, CompanionTurnOptions.voiceStylePrompt)
    }

    func testTelegramDeliveryOnlyForNumericChatIDs() {
        let options = CompanionTurnOptions.make(telegramChatID: " -100200 ", voiceStyle: false)
        XCTAssertEqual(options.replyDelivery, .init(channel: "telegram", to: "-100200", accountId: "default"))
        XCTAssertNil(CompanionTurnOptions.make(telegramChatID: "abc", voiceStyle: false).replyDelivery)
        XCTAssertNil(CompanionTurnOptions.make(telegramChatID: "-", voiceStyle: false).replyDelivery)
    }

    func testSettingsToggleGatesDelivery() {
        var settings = CompanionSettings()
        settings.telegramChatID = "42"
        XCTAssertNil(CompanionTurnOptions.make(from: settings).replyDelivery)
        settings.telegramEnabled = true
        XCTAssertEqual(CompanionTurnOptions.make(from: settings).replyDelivery?.to, "42")
    }
}
