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
