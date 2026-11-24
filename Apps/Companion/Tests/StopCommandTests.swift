import XCTest

final class StopCommandTests: XCTestCase {
    private let phrases = ["알프레드", "alfred"]

    func testBareStopWords() {
        for word in ["그만", "그만해", "그만해요", "멈춰", "됐어", "됐어요", "조용히", "스톱", "stop", "Stop!", "그만.", " 그만 해 요 "] {
            XCTAssertEqual(StopCommand.match(word, wakePhrases: phrases), .bare, word)
        }
    }

    func testAfterWakePhrase() {
        XCTAssertEqual(StopCommand.match("알프레드 그만", wakePhrases: phrases), .afterWakePhrase)
        XCTAssertEqual(StopCommand.match("알프레드, 그만해.", wakePhrases: phrases), .afterWakePhrase)
        XCTAssertEqual(StopCommand.match("알프레드야 멈춰", wakePhrases: phrases), .afterWakePhrase)
        XCTAssertEqual(StopCommand.match("Alfred, stop.", wakePhrases: phrases), .afterWakePhrase)
    }

    func testNonMatches() {
        for text in ["그만큼 비싸?", "멈춰 있는 차", "알프레드 그만큼 비싸?", "이제 됐어", "stop the music", "", "  ..."] {
            XCTAssertNil(StopCommand.match(text, wakePhrases: phrases), text)
        }
    }

    func testDecisionDuringReply() {
        // While a reply is spoken (or the echo window is open) a bare stop stops it…
        XCTAssertTrue(StopDecision.shouldStop(match: .bare, replyActive: true, echoOfReply: false, armed: false))
        // …unless it is the reply's own echo.
        XCTAssertFalse(StopDecision.shouldStop(match: .bare, replyActive: true, echoOfReply: true, armed: false))
        XCTAssertFalse(StopDecision.shouldStop(match: nil, replyActive: true, echoOfReply: false, armed: true))
    }

    func testDecisionOutsideReply() {
        // A bare "그만" is not addressed to the agent: ignored as before.
        XCTAssertFalse(StopDecision.shouldStop(match: .bare, replyActive: false, echoOfReply: false, armed: false))
        // Armed or with the name: a stop, never a request.
        XCTAssertTrue(StopDecision.shouldStop(match: .bare, replyActive: false, echoOfReply: false, armed: true))
        XCTAssertTrue(StopDecision.shouldStop(match: .afterWakePhrase, replyActive: false, echoOfReply: false, armed: false))
    }

    func testEchoWindowRecognisesTheReplySayingStop() {
        var echo = EchoWindow()
        let now = Date()
        echo.beganSpeaking("이제 그만 쉬세요.", at: now)
        XCTAssertTrue(echo.echoes("그만"))
        XCTAssertFalse(echo.echoes("스톱"))
    }
}
