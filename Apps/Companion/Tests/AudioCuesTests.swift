import XCTest

final class AudioCuesTests: XCTestCase {
    func testSamplesStayWithinGainAndStartAndEndSilent() {
        for earcon in Earcon.allCases {
            let samples = earcon.samples(sampleRate: 48_000)
            let peak = earcon.tones.map(\.gain).max() ?? 0
            XCTAssertFalse(samples.isEmpty, "\(earcon)")
            XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, peak + 0.0001, "\(earcon)")
            XCTAssertEqual(samples.first ?? 1, 0, accuracy: 0.001, "\(earcon) starts at zero (no click)")
            XCTAssertEqual(samples.last ?? 1, 0, accuracy: 0.02, "\(earcon) fades out")
        }
    }

    func testLengthIsTonesPlusGaps() {
        let rate = 10_000.0
        let accepted = Earcon.accepted
        let expected = accepted.tones.map { Int($0.duration * rate) }.reduce(0, +) + Int(0.03 * rate)
        XCTAssertEqual(accepted.samples(sampleRate: rate).count, expected)
    }

    func testThinkingIsQuieterThanTheOtherCues() {
        let thinking = Earcon.thinking.tones.map(\.gain).max() ?? 1
        for earcon in Earcon.allCases where earcon != .thinking {
            XCTAssertLessThan(thinking, earcon.tones.map(\.gain).min() ?? 0)
        }
    }

    func testThinkingTicksStartLateAndStop() {
        let schedule = ThinkingCueSchedule()
        XCTAssertEqual(schedule.tickTimes.first, 1.6)
        XCTAssertEqual(schedule.tickTimes[1], 3.6, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(schedule.tickTimes.last ?? 0, 90)
    }
}
