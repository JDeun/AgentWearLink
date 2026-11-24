import AgentWearLinkOpenClaw
import XCTest

final class OpenClawTurnOptionsAppendTests: XCTestCase {
    func testAppendsHintAfterExistingPromptWithBlankLine() {
        let base = OpenClawAgentTurnOptions(
            replyDelivery: .init(channel: "telegram", to: "1", accountId: "default"),
            extraSystemPrompt: "Answer briefly.",
            inputSourceChannel: "agentwearlink"
        )
        let combined = base.appendingSystemPrompt("  The attached photo is what the wearer sees.  ")
        XCTAssertEqual(combined.extraSystemPrompt, "Answer briefly.\n\nThe attached photo is what the wearer sees.")
        XCTAssertEqual(combined.replyDelivery, base.replyDelivery)
        XCTAssertEqual(combined.inputSourceChannel, "agentwearlink")
    }

    func testHintAloneWhenNoPrompt() {
        XCTAssertEqual(OpenClawAgentTurnOptions().appendingSystemPrompt("Photo.").extraSystemPrompt, "Photo.")
    }

    func testBlankOrNilHintKeepsOptions() {
        let base = OpenClawAgentTurnOptions(extraSystemPrompt: "x")
        XCTAssertEqual(base.appendingSystemPrompt(nil), base)
        XCTAssertEqual(base.appendingSystemPrompt("  \n"), base)
    }
}
