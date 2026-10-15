import XCTest

final class LaunchSetupCodeTests: XCTestCase {
    func testReadsTheValueAfterTheFlag() {
        XCTAssertEqual(LaunchSetupCode.value(in: ["App", "-AWLSetupCode", "abc123"]), "abc123")
    }

    func testTrimsWhitespaceAroundTheCode() {
        XCTAssertEqual(LaunchSetupCode.value(in: ["App", "-AWLSetupCode", "  abc123\n"]), "abc123")
    }

    func testMissingFlagMeansNoCode() {
        XCTAssertNil(LaunchSetupCode.value(in: ["App", "-AWLPreview", "home"]))
    }

    func testFlagWithoutValueMeansNoCode() {
        XCTAssertNil(LaunchSetupCode.value(in: ["App", "-AWLSetupCode"]))
    }

    func testAnotherFlagIsNotTakenAsTheCode() {
        XCTAssertNil(LaunchSetupCode.value(in: ["App", "-AWLSetupCode", "-AWLPreview"]))
    }

    func testBlankValueMeansNoCode() {
        XCTAssertNil(LaunchSetupCode.value(in: ["App", "-AWLSetupCode", "   "]))
    }
}

final class LaunchArgumentTests: XCTestCase {
    func testReadsSessionKeyAndChat() {
        let arguments = ["App", "-AWLSessionKey", "agent:main:telegram:default:direct:42", "-AWLTelegramChatID", "42"]
        XCTAssertEqual(LaunchArgument.value(LaunchArgument.sessionKey, in: arguments), "agent:main:telegram:default:direct:42")
        XCTAssertEqual(LaunchArgument.value(LaunchArgument.telegramChatID, in: arguments), "42")
    }

    func testNegativeChatIDIsNotTakenForAFlag() {
        // Group chat ids are negative; only a leading "-" followed by a
        // letter would look like a flag, but the parser rejects any "-".
        XCTAssertNil(LaunchArgument.value(LaunchArgument.telegramChatID, in: ["App", "-AWLTelegramChatID", "-100123"]))
    }
}
