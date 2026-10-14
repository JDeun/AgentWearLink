import AgentWearLinkCore
import XCTest

final class WakePhrasesTests: XCTestCase {
    func testHangulNameAddsVocativeWithoutFinalConsonant() {
        XCTAssertEqual(WakePhrases.defaults(forAgentName: "노바"), ["노바", "노바야", "헤이 노바"])
    }

    func testHangulNameAddsVocativeWithFinalConsonant() {
        XCTAssertEqual(WakePhrases.defaults(forAgentName: "하늘"), ["하늘", "하늘아", "헤이 하늘"])
    }

    func testLatinNameWithSpaces() {
        XCTAssertEqual(
            WakePhrases.defaults(forAgentName: " Iron Man "),
            ["Iron Man", "IronMan", "hey Iron Man", "헤이 Iron Man"]
        )
    }

    func testEmptyNameNeverForwardsEverything() {
        XCTAssertFalse(WakePhrases.defaults(forAgentName: "").isEmpty)
        let gate = AWLWakePhraseGate(wakePhrases: WakePhrases.defaults(forAgentName: ""))
        XCTAssertEqual(gate.evaluate("오늘 날씨 어때"), .ignore)
    }

    func testParseSplitsCommasAndNewlinesAndDeduplicates() {
        XCTAssertEqual(WakePhrases.parse("Nova, nova\n노바 ,,"), ["Nova", "노바"])
    }

    func testDefaultsDriveTheGate() {
        let gate = AWLWakePhraseGate(wakePhrases: WakePhrases.defaults(forAgentName: "노바"))
        XCTAssertEqual(gate.evaluate("노바야 불 꺼 줘"), .forward("불 꺼 줘"))
        XCTAssertEqual(gate.evaluate("노바, 안녕"), .forward("안녕"))
    }
}
