import XCTest

final class QualityMetricsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_986_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testTurnStagesReportedOnceWhenAudioStarts() {
        var tracker = TurnStageTracker()
        XCTAssertNil(tracker.forwarded(finalAt: t0, at: t0.addingTimeInterval(0.04)))
        XCTAssertTrue(tracker.awaitingText)
        tracker.replyText(at: t0.addingTimeInterval(2.14))
        tracker.replyText(at: t0.addingTimeInterval(3)) // later chunks ignored
        XCTAssertFalse(tracker.awaitingText)
        let stages = tracker.audioStarted(voice: .gateway, at: t0.addingTimeInterval(2.54))
        XCTAssertEqual(stages?.finalToForward ?? -1, 0.04, accuracy: 0.001)
        XCTAssertEqual(stages?.forwardToFirstText ?? -1, 2.1, accuracy: 0.001)
        XCTAssertEqual(stages?.firstTextToFirstAudio ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(
            stages?.logLine,
            "turn latency: final→forward 40 ms, forward→first text 2.1 s, first text→first audio 400 ms (gateway)"
        )
        XCTAssertNil(tracker.audioStarted(voice: .system, at: t0.addingTimeInterval(4)), "once per turn")
        XCTAssertNil(tracker.flush())
    }

    func testAudioWithoutATurnIsIgnored() {
        var tracker = TurnStageTracker()
        XCTAssertNil(tracker.audioStarted(voice: .system, at: t0), "e.g. the voice preview")
    }

    func testUnspokenTurnIsFlushedByTheNextRequest() {
        var tracker = TurnStageTracker()
        _ = tracker.forwarded(finalAt: t0, at: t0)
        tracker.replyText(at: t0.addingTimeInterval(1.5))
        let previous = tracker.forwarded(finalAt: t0.addingTimeInterval(10), at: t0.addingTimeInterval(10))
        XCTAssertEqual(previous?.forwardToFirstText ?? -1, 1.5, accuracy: 0.001)
        XCTAssertNil(previous?.firstTextToFirstAudio)
        XCTAssertTrue(previous?.logLine.hasSuffix("first text→first audio — (no audio)") ?? false)
    }

    func testCountersSinceLaunchAndToday() {
        var metrics = QualityMetrics(now: t0, calendar: utc)
        metrics.record(.forwarded, at: t0)
        metrics.record(.armedByName, at: t0)
        metrics.armedByTap(at: t0)
        metrics.record(.ignoredWithoutName, at: t0)
        metrics.record(.echoDropped, at: t0)
        metrics.record(.stop, at: t0)
        metrics.record(.empty, at: t0)
        metrics.stopped(.voice, at: t0)
        metrics.stopped(.tap, at: t0)
        metrics.noReply(at: t0)
        metrics.deafRestart(at: t0)
        let c = metrics.today
        XCTAssertEqual([c.forwards, c.armed, c.ignoredFinals, c.echoDrops, c.stops, c.noReplyForwards, c.deafRestarts],
                       [1, 2, 1, 1, 2, 1, 1])
        XCTAssertEqual(metrics.sinceLaunch, c)

        // Next day: today starts over, since-launch keeps counting.
        let tomorrow = t0.addingTimeInterval(86_400)
        metrics.record(.forwarded, at: tomorrow)
        XCTAssertEqual(metrics.today.forwards, 1)
        XCTAssertEqual(metrics.today.armed, 0)
        XCTAssertEqual(metrics.sinceLaunch.forwards, 2)
    }

    func testAvailabilityCountsOnlyWornMinutes() {
        var metrics = QualityMetrics(now: t0, calendar: utc)
        XCTAssertNil(metrics.today.availability)
        metrics.minute(worn: true, listening: true, at: t0)
        metrics.minute(worn: true, listening: true, at: t0)
        metrics.minute(worn: true, listening: false, at: t0)
        metrics.minute(worn: false, listening: true, at: t0)
        metrics.minute(worn: true, listening: true, at: t0)
        XCTAssertEqual(metrics.sinceLaunch.minutesWorn, 4)
        XCTAssertEqual(metrics.sinceLaunch.minutesListening, 3)
        XCTAssertEqual(metrics.today.availability ?? 0, 0.75, accuracy: 0.0001)
    }

    func testMedians() {
        XCTAssertNil(QualityMetrics.median([]))
        XCTAssertEqual(QualityMetrics.median([3, 1, 2]), 2)
        XCTAssertEqual(QualityMetrics.median([4, 1, 2, 3]), 2.5)
        var metrics = QualityMetrics(now: t0, calendar: utc)
        metrics.turn(TurnStages(finalToForward: 0.04, forwardToFirstText: 2), at: t0)
        metrics.turn(TurnStages(finalToForward: 0.06, forwardToFirstText: 4, firstTextToFirstAudio: 0.5, voice: .system), at: t0)
        XCTAssertEqual(metrics.medianToday(\.forwardToFirstText), 3)
        XCTAssertEqual(metrics.medianToday(\.firstTextToFirstAudio), 0.5)
        XCTAssertEqual(metrics.lastTurn?.voice, .system)
        metrics.turn(TurnStages(), at: t0.addingTimeInterval(86_400))
        XCTAssertNil(metrics.medianToday(\.forwardToFirstText), "today's turns roll over")
    }

    func testRecoveryWhileWanted() {
        var tracker = RecoveryTracker()
        XCTAssertNil(tracker.update(shouldListen: true, listening: false, at: t0), "nothing lost yet")
        tracker.lost("device session lost", shouldListen: true, at: t0)
        tracker.lost("gateway down", shouldListen: true, at: t0.addingTimeInterval(1)) // first reason wins
        XCTAssertNil(tracker.update(shouldListen: true, listening: false, at: t0.addingTimeInterval(5)))
        let recovery = tracker.update(shouldListen: true, listening: true, at: t0.addingTimeInterval(12))
        XCTAssertEqual(recovery?.reason, "device session lost")
        XCTAssertEqual(recovery?.logLine, "recovered in 12 s after device session lost")
        XCTAssertFalse(tracker.isDown)
        XCTAssertNil(tracker.update(shouldListen: true, listening: true, at: t0.addingTimeInterval(13)))
    }

    func testRecoveryClockPausesWhileNotWanted() {
        var tracker = RecoveryTracker()
        // Taken off: the clock waits until the glasses are worn again.
        tracker.lost("doff/fold pause", shouldListen: false, at: t0)
        XCTAssertNil(tracker.update(shouldListen: false, listening: false, at: t0.addingTimeInterval(600)))
        XCTAssertNil(tracker.update(shouldListen: true, listening: false, at: t0.addingTimeInterval(600)))
        // A call in between pauses it again.
        XCTAssertNil(tracker.update(shouldListen: false, listening: false, at: t0.addingTimeInterval(603)))
        XCTAssertNil(tracker.update(shouldListen: true, listening: false, at: t0.addingTimeInterval(700)))
        let recovery = tracker.update(shouldListen: true, listening: true, at: t0.addingTimeInterval(702))
        XCTAssertEqual(recovery?.seconds ?? -1, 5, accuracy: 0.001)
    }
}
