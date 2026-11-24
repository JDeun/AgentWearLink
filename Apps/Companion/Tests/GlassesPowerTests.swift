import XCTest

final class GlassesPowerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    // MARK: Holds

    func testCoolingRequiresObservedRecoveryEvenAfterTenMinutes() {
        let hold = GlassesHold.coolingDown(since: t0)
        func release(_ thermal: SpeechPowerPolicy.Thermal, after seconds: TimeInterval) -> Bool {
            GlassesHoldPolicy.shouldRelease(hold, thermal: thermal, battery: 50, charging: false, now: t0 + seconds, observedAt: t0 + seconds)
        }
        XCTAssertFalse(release(.critical, after: 180))
        XCTAssertFalse(release(.severe, after: 180))
        // Unknown is not evidence of cooling (stale after the session ended).
        XCTAssertFalse(release(.unknown, after: 180))
        XCTAssertTrue(release(.moderate, after: 180))
        // A peak-power shutdown at a normal level still waits the minimum.
        XCTAssertFalse(release(.normal, after: 1))
        XCTAssertTrue(release(.normal, after: GlassesHoldPolicy.minimumHold))
        XCTAssertFalse(release(.emergency, after: 599))
        XCTAssertFalse(release(.emergency, after: 600))
        XCTAssertFalse(release(.unknown, after: 86_400))
    }

    func testChargingReleasesOnChargeOrARise() {
        let hold = GlassesHold.charging(since: t0, battery: 6)
        func release(_ battery: Int?, charging: Bool = false, after seconds: TimeInterval = 180) -> Bool {
            GlassesHoldPolicy.shouldRelease(hold, thermal: .normal, battery: battery, charging: charging, now: t0 + seconds, observedAt: t0 + seconds)
        }
        XCTAssertFalse(release(6))
        XCTAssertFalse(release(8))
        XCTAssertTrue(release(9))
        XCTAssertTrue(release(6, charging: true))
        XCTAssertFalse(release(6, charging: true, after: 10))
        XCTAssertFalse(release(nil))
        XCTAssertFalse(release(nil, after: 86_400))
        XCTAssertFalse(release(5, charging: true, after: 86_400))
        XCTAssertFalse(release(6, after: 86_400))
        let unknownLevel = GlassesHold.charging(since: t0, battery: nil)
        XCTAssertFalse(GlassesHoldPolicy.shouldRelease(unknownLevel, thermal: .normal, battery: 15, charging: false, now: t0 + 180, observedAt: t0 + 180))
        XCTAssertTrue(GlassesHoldPolicy.shouldRelease(unknownLevel, thermal: .normal, battery: 16, charging: false, now: t0 + 180, observedAt: t0 + 180))
    }

    func testUpdatesDoNotRetryInALoop() {
        let glassesApp = GlassesHold.update(.glassesApp, since: t0)
        XCTAssertFalse(GlassesHoldPolicy.shouldRelease(glassesApp, thermal: .normal, battery: 80, charging: true, now: t0 + 60))
        XCTAssertTrue(GlassesHoldPolicy.shouldRelease(glassesApp, thermal: .normal, battery: 80, charging: true, now: t0 + 1800))
        // A new app build never arrives by waiting.
        let app = GlassesHold.update(.companionApp, since: t0)
        XCTAssertFalse(GlassesHoldPolicy.shouldRelease(app, thermal: .normal, battery: 80, charging: true, now: t0 + 86_400))
    }

    func testExplicitRequestsNeverOverrideHeat() {
        XCTAssertFalse(GlassesHoldPolicy.clearsOnUserRequest(.coolingDown(since: t0)))
        XCTAssertFalse(GlassesHoldPolicy.clearsOnUserRequest(.charging(since: t0, battery: 3)))
        XCTAssertTrue(GlassesHoldPolicy.clearsOnUserRequest(.update(.companionApp, since: t0)))
        XCTAssertTrue(GlassesHoldPolicy.clearsOnForeground(.update(.glassesFirmware, since: t0)))
        XCTAssertFalse(GlassesHoldPolicy.clearsOnForeground(.coolingDown(since: t0)))
        XCTAssertFalse(GlassesHoldPolicy.clearsOnForeground(.charging(since: t0, battery: 3)))
    }

    // MARK: Thermal stages

    func testEveryLevelMapsToAStage() {
        XCTAssertEqual(ThermalStageTracker.target(for: .unknown), .normal)
        XCTAssertEqual(ThermalStageTracker.target(for: .normal), .normal)
        XCTAssertEqual(ThermalStageTracker.target(for: .light), .normal)
        XCTAssertEqual(ThermalStageTracker.target(for: .moderate), .reduced)
        for level: SpeechPowerPolicy.Thermal in [.severe, .critical, .emergency, .shutdown] {
            XCTAssertEqual(ThermalStageTracker.target(for: level), .shed)
        }
    }

    func testStagesRiseAtOnceAndFallAfterADwell() {
        var tracker = ThermalStageTracker()
        XCTAssertNil(tracker.update(level: .light, at: t0))
        XCTAssertEqual(tracker.update(level: .moderate, at: t0), .reduced)
        XCTAssertEqual(tracker.update(level: .severe, at: t0 + 1), .shed)
        // Cooler, but not for long enough: stays shed.
        XCTAssertNil(tracker.update(level: .moderate, at: t0 + 2))
        XCTAssertNil(tracker.update(level: .moderate, at: t0 + 30))
        XCTAssertEqual(tracker.stage, .shed)
        XCTAssertEqual(tracker.update(level: .moderate, at: t0 + 62), .reduced)
        XCTAssertNil(tracker.update(level: .light, at: t0 + 63))
        XCTAssertEqual(tracker.update(level: .light, at: t0 + 123), .normal)
    }

    func testHoveringAtABoundaryDoesNotFlap() {
        var tracker = ThermalStageTracker()
        tracker.update(level: .moderate, at: t0)
        var changes = 0
        for second in stride(from: 1.0, through: 300, by: 10) {
            let level: SpeechPowerPolicy.Thermal = Int(second / 10) % 2 == 0 ? .moderate : .light
            if tracker.update(level: level, at: t0 + second) != nil { changes += 1 }
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(tracker.stage, .reduced)
    }

    func testThermalStageDrivesTheSpeechDecision() {
        let worn = GlassesDeviceObservation(link: .connected, wear: .worn, hinge: .open, thermal: .moderate)
        XCTAssertEqual(GlassesStateMapper.speechDecision([worn], thermalStage: .reduced), .listen)
        XCTAssertEqual(GlassesStateMapper.speechDecision([worn], thermalStage: .shed), .shedThermal)
        XCTAssertEqual(GlassesStateMapper.thermal([worn]), .moderate)
        XCTAssertEqual(SpeechPowerPolicy.decide(wear: .worn, hinge: .open, thermal: .light), .listen)
        XCTAssertEqual(SpeechPowerPolicy.decide(wear: .worn, hinge: .open, thermal: .moderate), .listen)
        XCTAssertEqual(SpeechPowerPolicy.decide(wear: .worn, hinge: .open, thermal: .shutdown), .shedThermal)
    }

    func testModerateHeatReducesOptionalWorkOnly() {
        for earcon in Earcon.allCases {
            XCTAssertTrue(ThermalWorkPolicy.allowsEarcon(earcon, stage: .normal))
        }
        XCTAssertTrue(ThermalWorkPolicy.allowsEarcon(.accepted, stage: .reduced))
        XCTAssertTrue(ThermalWorkPolicy.allowsEarcon(.failed, stage: .reduced))
        XCTAssertFalse(ThermalWorkPolicy.allowsEarcon(.thinking, stage: .reduced))
        XCTAssertFalse(ThermalWorkPolicy.allowsEarcon(.listening, stage: .reduced))
        XCTAssertNil(ThermalWorkPolicy.gatewayVoicePrefetchLimit(stage: .normal))
        XCTAssertEqual(ThermalWorkPolicy.gatewayVoicePrefetchLimit(stage: .reduced), 1)
        XCTAssertFalse(ThermalWorkPolicy.reducesSpeechStats(stage: .normal))
        XCTAssertTrue(ThermalWorkPolicy.reducesSpeechStats(stage: .reduced))
    }

    // MARK: Battery

    func testLowBatteryThreshold() {
        XCTAssertTrue(GlassesBatteryPolicy.isLow(battery: 15, charging: false))
        XCTAssertFalse(GlassesBatteryPolicy.isLow(battery: 16, charging: false))
        XCTAssertFalse(GlassesBatteryPolicy.isLow(battery: 5, charging: true))
        XCTAssertFalse(GlassesBatteryPolicy.isLow(battery: nil, charging: false))
    }

    func testLowBatteryIsLoggedOnceAndClearsWithHysteresis() {
        var notice = LowBatteryNotice()
        XCTAssertFalse(notice.update(battery: 40, charging: false))
        XCTAssertTrue(notice.update(battery: 15, charging: false))
        XCTAssertFalse(notice.update(battery: 14, charging: false))
        XCTAssertFalse(notice.update(battery: 16, charging: false))
        XCTAssertFalse(notice.update(battery: nil, charging: false))
        XCTAssertTrue(notice.active)
        XCTAssertFalse(notice.update(battery: 20, charging: false))
        XCTAssertTrue(notice.active)
        XCTAssertFalse(notice.update(battery: 21, charging: false))
        XCTAssertFalse(notice.active)
        XCTAssertTrue(notice.update(battery: 12, charging: false))
        XCTAssertFalse(notice.update(battery: 12, charging: true))
        XCTAssertFalse(notice.active)
    }

    func testObservationUpdateTargets() {
        XCTAssertEqual(GlassesDeviceObservation(link: .connected, updateRequired: true).update, .glassesFirmware)
        let sdk = GlassesDeviceObservation(link: .connected, update: .companionApp)
        XCTAssertEqual(GlassesStateMapper.snapshot(registered: true, devices: [sdk]).update, .companionApp)
    }

    func testUnknownThermalInterruptsCoolingDwell() {
        var tracker = ThermalStageTracker()
        XCTAssertEqual(tracker.update(level: .severe, at: t0), .shed)
        XCTAssertNil(tracker.update(level: .normal, at: t0 + 1))
        XCTAssertNil(tracker.update(level: .unknown, at: t0 + 62))
        XCTAssertNil(tracker.update(level: .normal, at: t0 + 1000))
        XCTAssertEqual(tracker.stage, .shed)
        XCTAssertEqual(tracker.update(level: .normal, at: t0 + 1060), .normal)
    }

    func testCameraPowerRefusalIsLocalAndBlocksFurtherSnapshots() {
        let heat = CameraPowerPolicy.hold(for: .thermalHot, battery: 50, now: t0)
        XCTAssertEqual(heat, .coolingDown(since: t0))
        XCTAssertEqual(CameraPowerPolicy.hold(for: .peakPowerLimit, battery: 80, now: t0), heat)
        XCTAssertEqual(CameraPowerPolicy.hold(for: .deviceHealthCritical, battery: nil, now: t0), heat)
        XCTAssertEqual(CameraPowerPolicy.hold(for: .batteryLow, battery: 10, now: t0), .charging(since: t0, battery: 10))
        XCTAssertNil(CameraPowerPolicy.hold(for: .streamFailed, battery: nil, now: t0))
        XCTAssertFalse(CameraPowerPolicy.allowsCapture(stage: .normal, localHold: heat, sessionHold: nil))
        XCTAssertFalse(CameraPowerPolicy.allowsCapture(stage: .normal, localHold: nil, sessionHold: heat))
        XCTAssertTrue(CameraPowerPolicy.allowsCapture(stage: .normal, localHold: nil, sessionHold: nil))
        XCTAssertFalse(CameraPowerPolicy.blocksReconnect(stage: .normal, sessionHold: nil, battery: 50, charging: false))
    }

    func testRecoveryAdmissionRejectsHeatAndCriticalBattery() {
        XCTAssertTrue(CameraPowerPolicy.blocksReconnect(stage: .shed, sessionHold: nil, battery: 80, charging: true))
        XCTAssertTrue(CameraPowerPolicy.blocksReconnect(stage: .normal, sessionHold: nil, battery: 5, charging: false))
        XCTAssertTrue(CameraPowerPolicy.blocksReconnect(stage: .normal, sessionHold: .coolingDown(since: t0), battery: 80, charging: false))
        XCTAssertFalse(CameraPowerPolicy.blocksReconnect(stage: .reduced, sessionHold: nil, battery: 40, charging: false))
    }

    func testPowerHoldRejectsMissingStaleOrPreFailureObservation() {
        let hold = GlassesHold.coolingDown(since: t0)
        let now = t0 + 300
        func release(_ stamp: Date?) -> Bool {
            GlassesHoldPolicy.shouldRelease(hold, thermal: .normal, battery: 80,
                                           charging: false, now: now, observedAt: stamp)
        }
        XCTAssertFalse(release(nil))
        XCTAssertFalse(release(t0))
        XCTAssertFalse(release(t0 + 1))
        XCTAssertFalse(release(now + 1))
        XCTAssertTrue(release(now))
        XCTAssertTrue(CameraPowerPolicy.blocksReconnect(stage: .normal, sessionHold: nil, battery: 5, charging: true))
    }
}
