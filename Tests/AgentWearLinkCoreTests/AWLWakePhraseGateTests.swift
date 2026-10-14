import XCTest
@testable import AgentWearLinkCore

final class AWLWakePhraseGateTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private lazy var gate = AWLWakePhraseGate(
        wakePhrases: ["알프레드", "Alfred"],
        armedWindow: 8,
        clock: { [unowned self] in self.now }
    )

    func testRequestAfterWakePhraseIsForwardedWithoutThePhrase() {
        XCTAssertEqual(gate.evaluate("알프레드, 현재 위치 기준으로 카페 추천해줘"),
                       .forward("현재 위치 기준으로 카페 추천해줘"))
        XCTAssertEqual(gate.evaluate("Alfred what time is it"), .forward("what time is it"))
        XCTAssertEqual(gate.evaluate("alfred. 날씨 어때?"), .forward("날씨 어때?"))
    }

    func testSpeechWithoutWakePhraseIsIgnored() {
        XCTAssertEqual(gate.evaluate("오늘 점심 뭐 먹지"), .ignore)
        XCTAssertEqual(gate.evaluate("Hey Meta, what's the weather"), .ignore)
        // The name inside a sentence is not a wake phrase.
        XCTAssertEqual(gate.evaluate("어제 알프레드가 말한 거"), .ignore)
    }

    func testWakePhraseAloneArmsTheNextUtterance() {
        XCTAssertEqual(gate.evaluate("알프레드"), .armed)
        now += 3
        XCTAssertEqual(gate.evaluate("지금 몇 시야"), .forward("지금 몇 시야"))
        // One request per arming.
        XCTAssertEqual(gate.evaluate("그리고 날씨는"), .ignore)
    }

    func testArmingExpires() {
        XCTAssertEqual(gate.evaluate("알프레드"), .armed)
        now += 9
        XCTAssertEqual(gate.evaluate("지금 몇 시야"), .ignore)
    }

    func testExplicitArmFromAGestureForwardsTheNextUtterance() {
        gate.arm()
        XCTAssertEqual(gate.evaluate("지금 몇 시야"), .forward("지금 몇 시야"))
    }

    func testTranscriptsDuringAndShortlyAfterSpokenReplyAreSuppressed() {
        gate.suppress(until: now + 4)
        XCTAssertEqual(gate.evaluate("알프레드, 이건 에코"), .ignore)
        now += 5
        XCTAssertEqual(gate.evaluate("알프레드, 이제 진짜 질문"), .forward("이제 진짜 질문"))
    }

    func testEmptyAndPunctuationOnlyTextIsIgnored() {
        XCTAssertEqual(gate.evaluate("   "), .ignore)
        XCTAssertEqual(gate.evaluate("알프레드 ... "), .armed)
    }

    func testNoWakePhrasesForwardsEverything() {
        let open = AWLWakePhraseGate(wakePhrases: [], armedWindow: 8, clock: { Date() })
        XCTAssertEqual(open.evaluate("지금 몇 시야"), .forward("지금 몇 시야"))
    }
}

final class AWLWakePhraseGateFuzzyHangulTests: XCTestCase {
    private func gate() -> AWLWakePhraseGate {
        AWLWakePhraseGate(wakePhrases: ["알프레드", "Alfred"])
    }

    func testCommonMisspellingsStillWake() {
        XCTAssertEqual(gate().evaluate("알프래드 불 꺼 줘"), .forward("불 꺼 줘"))
        XCTAssertEqual(gate().evaluate("알프레도, 날씨 어때"), .forward("날씨 어때"))
        XCTAssertEqual(gate().evaluate("앨프레드 안녕"), .forward("안녕"))
        XCTAssertEqual(gate().evaluate("알프레드야 오늘 일정"), .forward("오늘 일정"))
        XCTAssertEqual(gate().evaluate("알프레드님 안녕"), .forward("안녕"))
        // Field log 2026-10-14: the glasses recognizer split 알 into 아이.
        XCTAssertEqual(gate().evaluate("아이프레드 지금 몇 시야?"), .forward("지금 몇 시야?"))
    }

    func testBareNameWithPunctuationArms() {
        XCTAssertEqual(gate().evaluate("알프레드 ,"), .armed)
    }

    func testDifferentWordsDoNotWake() {
        XCTAssertEqual(gate().evaluate("알바 구하는 중"), .ignore)
        XCTAssertEqual(gate().evaluate("아프리카 여행"), .ignore)
        XCTAssertEqual(gate().evaluate("아이폰 충전해"), .ignore)
        XCTAssertEqual(gate().evaluate("프레드 왔어"), .ignore)
        XCTAssertEqual(gate().evaluate("오늘 알프레드 봤어"), .ignore)
    }

    func testLatinKeepsTheWordBoundaryRule() {
        XCTAssertEqual(gate().evaluate("Alfred, hello"), .forward("hello"))
        XCTAssertEqual(gate().evaluate("Alfredo hello"), .ignore)
    }

    func testLongerNamesAllowTwoEdits() {
        let gate = AWLWakePhraseGate(wakePhrases: ["크리스토퍼"])
        XCTAssertEqual(gate.evaluate("크리스토파 안녕"), .forward("안녕"))
        XCTAssertEqual(AWLHangulFuzzy.editDistance(AWLHangulFuzzy.jamo("노바"), AWLHangulFuzzy.jamo("노마"), limit: 1), 1)
    }

    func testMultiWordPhrase() {
        let gate = AWLWakePhraseGate(wakePhrases: ["헤이 노바"])
        XCTAssertEqual(gate.evaluate("헤이 노바야 안녕"), .forward("안녕"))
    }
}
