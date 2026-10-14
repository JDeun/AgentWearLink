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
