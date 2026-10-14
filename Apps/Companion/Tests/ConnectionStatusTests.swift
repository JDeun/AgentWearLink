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
        XCTAssertEqual(state.rows[1].state, .checking)
        XCTAssertEqual(state.banner, .checking)
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
