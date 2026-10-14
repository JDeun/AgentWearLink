import XCTest

final class SentenceSplitterTests: XCTestCase {
    func testKoreanAndEnglishSentences() {
        let result = SentenceSplitter.split("안녕하세요. 오늘 날씨는 맑아요! Is that ok? 다음")
        XCTAssertEqual(result.sentences, ["안녕하세요.", "오늘 날씨는 맑아요!", "Is that ok?"])
        XCTAssertEqual(result.remainder, " 다음")
    }

    func testNumbersAndVersionsDoNotSplit() {
        let result = SentenceSplitter.split("온도는 3.5도예요. v1.2 버전")
        XCTAssertEqual(result.sentences, ["온도는 3.5도예요."])
        XCTAssertEqual(SentenceSplitter.split("3.5", final: true).sentences, ["3.5"])
    }

    func testEllipsisRunsStayTogether() {
        let result = SentenceSplitter.split("음... 잠깐만요… 네?! 끝", final: true)
        XCTAssertEqual(result.sentences, ["음...", "잠깐만요…", "네?!", "끝"])
    }

    func testTerminatorAtBufferEndWaitsForMore() {
        // "3." might continue as "3.5": not complete yet.
        XCTAssertEqual(SentenceSplitter.split("값은 3.").sentences, [])
        XCTAssertEqual(SentenceSplitter.split("값은 3.", final: true).sentences, ["값은 3."])
    }

    func testNewlinesAndControlLines() {
        let result = SentenceSplitter.split("{\"tts\": \"off. now\"}\n첫 줄\n둘째 줄", final: true)
        XCTAssertEqual(result.sentences, ["{\"tts\": \"off. now\"}", "첫 줄", "둘째 줄"])
        XCTAssertNil(TTSControlFilter.speakable(result.sentences[0]))
        XCTAssertEqual(TTSControlFilter.speakable(result.sentences[1]), "첫 줄")
    }

    func testControlFilterKeepsNormalBraces() {
        XCTAssertEqual(TTSControlFilter.speakable("{ not json }"), "{ not json }")
        XCTAssertEqual(TTSControlFilter.speakable("말\n{\"voice\":\"short\"}"), "말")
    }
}

final class CallGateTests: XCTestCase {
    func testRecoversWhenTheLastCallEnds() {
        var gate = CallGate()
        XCTAssertTrue(gate.allowsReconnect)
        XCTAssertEqual(gate.update(callActive: true), .callStarted)
        XCTAssertFalse(gate.allowsReconnect)
        XCTAssertEqual(gate.update(callActive: true), .none)
        XCTAssertEqual(gate.update(callActive: false), .lastCallEnded)
        XCTAssertTrue(gate.allowsReconnect)
        XCTAssertEqual(gate.update(callActive: false), .none)
    }
}

final class EchoWindowQueueTests: XCTestCase {
    func testQueuedSentencesKeepTheGateClosedUntilTheLastFinishes() {
        var window = EchoWindow()
        let t0 = Date(timeIntervalSince1970: 0)
        window.beganSpeaking("첫 문장", at: t0)
        window.beganSpeaking(String(repeating: "가", count: 50), at: t0)
        window.finishedSpeaking(at: t0.addingTimeInterval(1))
        // Still one queued: the window is not shortened.
        XCTAssertTrue(window.suppresses(at: t0.addingTimeInterval(9)))
        window.finishedSpeaking(at: t0.addingTimeInterval(10))
        XCTAssertTrue(window.suppresses(at: t0.addingTimeInterval(13.9)))
        XCTAssertFalse(window.suppresses(at: t0.addingTimeInterval(14.1)))
    }
}
