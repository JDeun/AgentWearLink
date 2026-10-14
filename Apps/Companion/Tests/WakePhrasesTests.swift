import AgentWearLinkCore
import XCTest

final class WakePhrasesTests: XCTestCase {
    func testHangulNameAddsKoreanVariantsInKoreanUI() {
        XCTAssertEqual(WakePhrases.defaults(forAgentName: "노바", korean: true), ["노바", "노바야", "헤이 노바"])
        XCTAssertEqual(WakePhrases.defaults(forAgentName: "하늘", korean: true), ["하늘", "하늘아", "헤이 하늘"])
    }

    func testEnglishUINeverAddsKoreanVariants() {
        XCTAssertEqual(WakePhrases.defaults(forAgentName: "노바", korean: false), ["노바"])
        XCTAssertEqual(WakePhrases.defaults(forAgentName: "Nova", korean: false), ["Nova", "hey Nova"])
        XCTAssertEqual(WakePhrases.fallback(korean: false), ["agent"])
    }

    func testLatinNameIsNeverMixedWithKoreanHey() {
        let phrases = WakePhrases.defaults(forAgentName: " Iron Man ", korean: true)
        XCTAssertEqual(phrases, ["Iron Man", "IronMan", "hey Iron Man"])
        XCTAssertFalse(phrases.contains { $0.hasPrefix("헤이") })
    }

    func testSpokenNameAddsTheKoreanPronunciation() {
        let phrases = WakePhrases.defaults(agentName: "Alfred", spokenName: "알프레드", korean: true)
        XCTAssertEqual(phrases, ["Alfred", "hey Alfred", "알프레드", "알프레드야", "헤이 알프레드"])
        let gate = AWLWakePhraseGate(wakePhrases: phrases)
        XCTAssertEqual(gate.evaluate("알프레드 오늘 일정 알려줘"), .forward("오늘 일정 알려줘"))
    }

    func testNeedsPronunciationOnlyForNonHangulNames() {
        XCTAssertTrue(WakePhrases.needsPronunciation(agentName: "Alfred"))
        XCTAssertFalse(WakePhrases.needsPronunciation(agentName: "노바"))
        XCTAssertFalse(WakePhrases.needsPronunciation(agentName: " "))
    }

    func testCandidateIsTheFirstHeardWord() {
        XCTAssertEqual(WakePhrases.candidate(fromIgnored: "알프레드 안녕"), "알프레드")
        XCTAssertEqual(WakePhrases.candidate(fromIgnored: "  알프레도, 안녕"), "알프레도")
        XCTAssertNil(WakePhrases.candidate(fromIgnored: "아"))
        XCTAssertNil(WakePhrases.candidate(fromIgnored: " ... "))
    }

    func testAddingAHeardWordMakesThePracticeMatch() {
        var settings = CompanionSettings()
        settings.agentName = "Alfred"
        let heard = "알프레도 안녕"
        XCTAssertEqual(AWLWakePhraseGate(wakePhrases: settings.effectiveWakePhrases(korean: true)).evaluate(heard), .ignore)
        settings.addWakePhrase(WakePhrases.candidate(fromIgnored: heard)!, korean: true)
        XCTAssertEqual(settings.wakePhrases, ["Alfred", "hey Alfred", "알프레도"])
        XCTAssertEqual(AWLWakePhraseGate(wakePhrases: settings.effectiveWakePhrases(korean: true)).evaluate(heard), .forward("안녕"))
    }

    func testEmptyNameNeverForwardsEverything() {
        let gate = AWLWakePhraseGate(wakePhrases: WakePhrases.defaults(forAgentName: "", korean: true))
        XCTAssertEqual(gate.evaluate("오늘 날씨 어때"), .ignore)
    }

    func testParseSplitsCommasAndNewlinesAndDeduplicates() {
        XCTAssertEqual(WakePhrases.parse("Nova, nova\n노바 ,,"), ["Nova", "노바"])
    }

    func testDefaultsDriveTheGate() {
        let gate = AWLWakePhraseGate(wakePhrases: WakePhrases.defaults(forAgentName: "노바", korean: true))
        XCTAssertEqual(gate.evaluate("노바야 불 꺼 줘"), .forward("불 꺼 줘"))
        XCTAssertEqual(gate.evaluate("노바, 안녕"), .forward("안녕"))
    }
}

final class KoreanParticleTests: XCTestCase {
    func testObjectParticle() {
        XCTAssertEqual(KoreanParticle.object(after: "알프레도"), "를")
        XCTAssertEqual(KoreanParticle.object(after: "하늘"), "을")
        XCTAssertEqual(KoreanParticle.object(after: "Alfred"), "을(를)")
    }
}
