import AgentWearLinkCore
import XCTest

final class ConnectionStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func healthy() -> ConnectionSignals {
        var signals = ConnectionSignals()
        signals.glasses = .connected
        signals.glassesBattery = 72
        signals.microphone = .granted
        signals.listening = true
        signals.speechReady = true
        signals.network = .reachable
        signals.gateway = .ok
        signals.lastReplyAt = now
        for id in AWLChainLinkID.allCases { signals.checkedAt[id] = now }
        return signals
    }

    func testAllConnected() {
        let state = HomeViewState(signals: healthy(), telegramConfigured: false)
        XCTAssertEqual(state.banner, .allConnected(checkedAt: now))
        XCTAssertTrue(state.rows.allSatisfy { $0.state == .ok })
        XCTAssertFalse(state.showsTelegramLink)
    }

    func testGlassesInCaseIsWaitingNotAnError() {
        var signals = healthy()
        signals.glasses = .waiting
        signals.glassesBattery = nil
        let state = HomeViewState(signals: signals, telegramConfigured: true)
        XCTAssertEqual(state.banner, .waitingForGlasses)
        XCTAssertEqual(state.rows[0].state, .waiting)
        // The rest of the chain is still checked, not hidden behind the glasses.
        XCTAssertEqual(state.rows[3].state, .ok)
        XCTAssertNil(signals.chain.firstProblem)
        XCTAssertTrue(state.showsTelegramLink)
    }

    func testWaitingWhileGatewayNotYetCheckedIsStillWaiting() {
        var signals = ConnectionSignals()
        signals.glasses = .waiting
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.banner, .waitingForGlasses)
        XCTAssertEqual(state.rows[3].state, .checking)
    }

    func testRealProblemWinsOverWaiting() {
        var signals = healthy()
        signals.glasses = .waiting
        signals.network = .unreachable
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        guard case let .problem(problem) = state.banner else { return XCTFail("\(state.banner)") }
        XCTAssertEqual(problem.link, .network)
        XCTAssertEqual(problem.reason, .networkUnreachable)
        XCTAssertEqual(state.rows[3].state, .notCheckable)
        XCTAssertEqual(state.rows[4].state, .notCheckable)
    }

    func testRegistrationMissingBreaksGlassesHop() {
        var signals = healthy()
        signals.glasses = .registrationRequired
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.rows[0].state, .problem(.metaRegistrationMissing))
        XCTAssertEqual(state.rows[1].state, .notCheckable)
    }

    func testCriticalBatteryOnlyWhenNotCharging() {
        var signals = healthy()
        signals.glassesBattery = 4
        XCTAssertEqual(signals.observations[.glasses], .broken(.glassesBatteryCritical))
        signals.glassesCharging = true
        XCTAssertEqual(signals.observations[.glasses], .ok)
    }

    func testPairingStates() {
        var signals = healthy()
        signals.gateway = .pairingPending
        XCTAssertEqual(signals.chain.firstProblem?.reason, .pairingPending)
        signals.gateway = .pairingRevoked
        XCTAssertEqual(signals.chain.firstProblem?.reason, .pairingRevoked)
    }

    func testAgentWithoutAnyReplyIsUnknownNotOk() {
        var signals = healthy()
        signals.lastReplyAt = nil
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.rows[4].state, .checking)
        // Glasses through gateway are verified, so the banner is still green.
        XCTAssertEqual(state.banner, .allConnected(checkedAt: now))
    }

    func testConnectedWithoutSpeechIsNotAllConnected() {
        var signals = healthy()
        signals.speechReady = false
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.rows[1].state, .notListening)
        XCTAssertEqual(state.banner, .notListening)
        XCTAssertFalse(state.showsCallHint)
    }

    func testFailedConnectWithGlassesOnIsNotListening() {
        var signals = healthy()
        signals.listening = false
        signals.speechReady = false
        XCTAssertEqual(HomeViewState(signals: signals, telegramConfigured: false).banner, .checking)
        signals.listenFailed = true
        XCTAssertEqual(HomeViewState(signals: signals, telegramConfigured: false).banner, .notListening)
    }

    func testRevokedGrantDoesNotClaimThePhoneIsConnecting() {
        var signals = healthy()
        signals.listening = false
        signals.speechReady = false
        signals.gateway = .pairingRevoked
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.rows[1].state, .ok)
        XCTAssertEqual(state.rows[3].state, .problem(.pairingRevoked))
        guard case .problem = state.banner else { return XCTFail("\(state.banner)") }
    }

    func testCallHintOnlyWhileListening() {
        XCTAssertTrue(HomeViewState(signals: healthy(), telegramConfigured: false).showsCallHint)
        var waiting = healthy()
        waiting.glasses = .waiting
        XCTAssertFalse(HomeViewState(signals: waiting, telegramConfigured: false).showsCallHint)
    }

    func testStatusLabelsAreSpecific() {
        func label(_ id: AWLChainLinkID, _ state: HomeViewState.RowState) -> HomeViewState.StatusLabel {
            HomeViewState.statusLabel(for: .init(id: id, state: state, checkedAt: nil))
        }
        XCTAssertEqual(label(.gateway, .problem(.pairingPending)), .needsApproval)
        XCTAssertEqual(label(.gateway, .problem(.pairingRevoked)), .needsApproval)
        XCTAssertEqual(label(.glasses, .problem(.glassesBatteryCritical)), .needsCharging)
        XCTAssertEqual(label(.glasses, .problem(.glassesUpdateRequired)), .updateNeeded)
        XCTAssertEqual(label(.network, .problem(.networkUnreachable)), .disconnected)
        XCTAssertEqual(label(.agent, .problem(.agentNotResponding)), .notResponding)
        XCTAssertEqual(label(.agent, .ok), .answered)
        XCTAssertEqual(label(.glasses, .waiting), .waiting)
    }

    func testGlassesConnectedButRuntimeNotUpYetIsChecking() {
        var signals = healthy()
        signals.listening = false
        signals.speechReady = false
        XCTAssertNil(signals.observations[.phone])
        // Waiting glasses never need a running runtime for the phone hop.
        signals.glasses = .waiting
        XCTAssertEqual(signals.observations[.phone], .ok)
    }

    func testListeningOffIsNeutral() {
        var signals = healthy()
        signals.listenEnabled = false
        XCTAssertEqual(HomeViewState(signals: signals, telegramConfigured: false).banner, .listeningOff)
    }

    func testMicrophoneDeniedBreaksPhoneHop() {
        var signals = healthy()
        signals.microphone = .denied
        XCTAssertEqual(signals.chain.firstProblem?.reason, .microphoneDenied)
    }

    func testBannerCheckedAtIsTheOldestVerifiedHop() {
        var signals = healthy()
        signals.checkedAt[.network] = now.addingTimeInterval(-30)
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.banner, .allConnected(checkedAt: now.addingTimeInterval(-30)))
    }

    func testRepairGuideForNetworkOffersTailscaleHint() {
        var signals = healthy()
        signals.network = .unreachable
        let guide = RepairGuide(problem: signals.chain.firstProblem!)
        XCTAssertEqual(guide.causes, [.tailscaleOff, .hostAsleep, .weakInternet])
        XCTAssertEqual(guide.action, .recheck)
        XCTAssertTrue(guide.showsTailscaleOnDemandHint)
    }

    func testEveryReasonHasARepairGuide() {
        for reason in AWLChainProblemReason.allCases where reason != .appNotRunning {
            let chain = AWLConnectionChain(observations: [.glasses: .broken(reason)])
            let guide = RepairGuide(problem: chain.firstProblem!)
            XCTAssertFalse(guide.causes.isEmpty, "\(reason)")
            XCTAssertNotNil(guide.action)
        }
    }
}

final class SpeechPauseStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func healthy() -> ConnectionSignals {
        var signals = ConnectionSignals()
        signals.glasses = .connected
        signals.glassesBattery = 72
        signals.microphone = .granted
        signals.listening = true
        signals.speechReady = true
        signals.network = .reachable
        signals.gateway = .ok
        signals.lastReplyAt = now
        for id in AWLChainLinkID.allCases { signals.checkedAt[id] = now }
        return signals
    }

    private func worn() -> ConnectionSignals {
        var signals = ConnectionSignals()
        signals.glasses = .connected
        signals.microphone = .granted
        signals.network = .reachable
        signals.gateway = .ok
        signals.listening = false
        signals.speechReady = false
        signals.listenFailed = true
        return signals
    }

    func testTakenOffIsRestingNotAnError() {
        var signals = worn()
        signals.speechPause = .pauseNotWorn
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.banner, .waitingForGlasses)
        XCTAssertEqual(state.rows[0].state, .resting)
        XCTAssertNotEqual(state.rows[1].state, .notListening)
    }

    func testHeatIsShownAsShed() {
        var signals = worn()
        signals.speechPause = .shedThermal
        XCTAssertEqual(HomeViewState(signals: signals, telegramConfigured: false).banner, .thermalShed)
    }

    // Session ended by heat: a wait, not "not listening".
    func testCoolingDownIsAWaitNotAProblem() {
        var signals = worn()
        signals.hold = .coolingDown(since: now)
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.banner, .coolingDown)
        XCTAssertFalse(signals.isNotListening)
        XCTAssertEqual(state.rows[1].state, .ok)
        XCTAssertNil(signals.chain.firstProblem)
    }

    func testBatteryCriticalSessionEndWaitsForCharge() {
        var signals = worn()
        signals.glassesBattery = 9
        signals.hold = .charging(since: now, battery: 9)
        XCTAssertEqual(HomeViewState(signals: signals, telegramConfigured: false).banner, .waitingForCharge)
    }

    func testAnUpstreamProblemStillWinsOverAWait() {
        var signals = worn()
        signals.hold = .coolingDown(since: now)
        signals.network = .unreachable
        let banner = HomeViewState(signals: signals, telegramConfigured: false).banner
        guard case let .problem(problem) = banner else { return XCTFail("\(banner)") }
        XCTAssertEqual(problem.reason, .networkUnreachable)
    }

    // Update-required session errors use the existing update banner.
    func testUpdateHoldShowsTheUpdateBannerWithItsTarget() {
        var signals = worn()
        signals.hold = .update(.glassesApp, since: now)
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        guard case let .problem(problem) = state.banner else { return XCTFail("\(state.banner)") }
        XCTAssertEqual(problem.reason, .glassesUpdateRequired)
        XCTAssertEqual(state.updateTarget, .glassesApp)
    }

    func testCompatibilityUpdateTargets() {
        var signals = healthy()
        signals.glasses = .updateRequired
        XCTAssertEqual(signals.updateTarget, .glassesFirmware)
        signals.glassesUpdate = .companionApp
        XCTAssertEqual(HomeViewState(signals: signals, telegramConfigured: false).updateTarget, .companionApp)
        XCTAssertNil(HomeViewState(signals: healthy(), telegramConfigured: false).updateTarget)
    }

    func testLowBatteryIsAGentleNoticeNotABanner() {
        var signals = healthy()
        signals.glassesBattery = 14
        signals.glassesBatteryLow = true
        let state = HomeViewState(signals: signals, telegramConfigured: false)
        XCTAssertEqual(state.banner, .allConnected(checkedAt: now))
        XCTAssertEqual(state.lowBattery, 14)
        signals.glassesCharging = true
        XCTAssertNil(HomeViewState(signals: signals, telegramConfigured: false).lowBattery)
        signals.glassesCharging = false
        signals.glassesBattery = 4
        // Critical is the existing problem banner, not the notice.
        XCTAssertNil(HomeViewState(signals: signals, telegramConfigured: false).lowBattery)
    }
}
