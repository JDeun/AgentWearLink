import XCTest

final class AudioPoliciesTests: XCTestCase {
    func testRepliesOnlyIntoTheEar() {
        XCTAssertTrue(AudioRoutePolicy.canSpeakAloud(outputs: [.bluetoothA2DP]))
        XCTAssertTrue(AudioRoutePolicy.canSpeakAloud(outputs: [.bluetoothLE]))
        XCTAssertTrue(AudioRoutePolicy.canSpeakAloud(outputs: [.headphones]))
        XCTAssertFalse(AudioRoutePolicy.canSpeakAloud(outputs: [.builtInSpeaker]))
        XCTAssertFalse(AudioRoutePolicy.canSpeakAloud(outputs: [.builtInReceiver]))
        XCTAssertFalse(AudioRoutePolicy.canSpeakAloud(outputs: [.bluetoothHFP]))
        XCTAssertFalse(AudioRoutePolicy.canSpeakAloud(outputs: []))
    }

    func testInterruptionEndRecoversNow() {
        let ended = AudioEventPolicy.actions(for: .interruptionEnded, listeningWanted: true)
        XCTAssertTrue(ended.restartKeepAlive)
        XCTAssertTrue(ended.recoverSessionNow)
        XCTAssertFalse(ended.recreateSynthesizer)
        let reset = AudioEventPolicy.actions(for: .mediaServicesReset, listeningWanted: true)
        XCTAssertTrue(reset.recreateSynthesizer)
        XCTAssertTrue(reset.recoverSessionNow)
        XCTAssertEqual(AudioEventPolicy.actions(for: .interruptionBegan, listeningWanted: true), .init())
        XCTAssertEqual(AudioEventPolicy.actions(for: .interruptionEnded, listeningWanted: false), .init())
    }

    func testEchoWindowShrinksToRealEndPlusTail() {
        var window = EchoWindow()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(window.suppresses(at: start))
        window.beganSpeaking(String(repeating: "가", count: 100), at: start)
        XCTAssertTrue(window.suppresses(at: start.addingTimeInterval(20)))
        window.finishedSpeaking(at: start.addingTimeInterval(5))
        XCTAssertTrue(window.suppresses(at: start.addingTimeInterval(8.9)))
        XCTAssertFalse(window.suppresses(at: start.addingTimeInterval(9.1)))
    }

    func testEchoEstimateIsCapped() {
        var window = EchoWindow()
        let start = Date(timeIntervalSince1970: 0)
        window.beganSpeaking(String(repeating: "a", count: 100_000), at: start)
        XCTAssertFalse(window.suppresses(at: start.addingTimeInterval(EchoWindow.maximumEstimate + EchoWindow.tail + 1)))
    }
}

final class EchoWindowContentTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func windowAfterReply(_ reply: String) -> EchoWindow {
        var window = EchoWindow()
        window.beganSpeaking(reply, at: start)
        window.finishedSpeaking(at: start.addingTimeInterval(3))
        return window
    }

    func testWhileSpeakingEverythingIsSuppressed() {
        var window = EchoWindow()
        window.beganSpeaking("지금 밤 10시 59분입니다, 주인님.", at: start)
        XCTAssertTrue(window.suppresses("그럼 내일 날씨는", at: start.addingTimeInterval(1)))
    }

    func testTailDropsOnlyTheReplyEcho() {
        let window = windowAfterReply("지금 밤 10시 59분입니다, 주인님.")
        let inTail = start.addingTimeInterval(4)
        XCTAssertTrue(window.suppresses("지금 밤 10시 59분입니다", at: inTail))
        XCTAssertTrue(window.suppresses("59분입니다 주인님", at: inTail))
        // The wearer's follow-up right after the reply must get through.
        XCTAssertFalse(window.suppresses("그럼 내일 날씨는", at: inTail))
        XCTAssertFalse(window.suppresses("알프레드 내일 일정 알려줘", at: inTail))
    }

    func testAfterTheTailNothingIsSuppressed() {
        let window = windowAfterReply("지금 밤 10시 59분입니다, 주인님.")
        XCTAssertFalse(window.suppresses("지금 밤 10시 59분입니다", at: start.addingTimeInterval(3 + EchoWindow.tail + 0.1)))
    }
}
