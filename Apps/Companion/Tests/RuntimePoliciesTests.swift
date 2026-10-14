import AgentWearLinkOpenClaw
import XCTest

final class RuntimePoliciesTests: XCTestCase {
    func testListeningPolicy() {
        XCTAssertTrue(ListeningPolicy.wantsListening(setupCompleted: true, listenEnabled: true, practicing: false))
        XCTAssertTrue(ListeningPolicy.wantsListening(setupCompleted: false, listenEnabled: true, practicing: true))
        XCTAssertFalse(ListeningPolicy.wantsListening(setupCompleted: false, listenEnabled: true, practicing: false))
        XCTAssertFalse(ListeningPolicy.wantsListening(setupCompleted: true, listenEnabled: false, practicing: true))
    }

    func testWatchKeepsAHealthySession() {
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .ready, healthFailure: nil, consecutiveFailures: 0), .keep)
    }

    func testWatchToleratesOneHealthBlip() {
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .ready, healthFailure: .gatewayUnreachable, consecutiveFailures: 1), .keep)
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .ready, healthFailure: .gatewayUnreachable, consecutiveFailures: 2), .reconnect)
    }

    func testWatchReplacesAPermanentlyStoppedSupervisor() {
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .disconnected, healthFailure: nil, consecutiveFailures: 0), .reconnect)
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .failed("x"), healthFailure: nil, consecutiveFailures: 0), .reconnect)
    }

    func testWatchGivesTheSupervisorReconnectTime() {
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .reconnecting(attempt: 2), healthFailure: nil, consecutiveFailures: 3), .keep)
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .reconnecting(attempt: 5), healthFailure: nil, consecutiveFailures: 4), .reconnect)
    }

    func testRevokedGrantStopsAndAsksToReapprove() {
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .ready, healthFailure: .pairingRevoked, consecutiveFailures: 1), .stopNeedsApproval)
        XCTAssertEqual(VoiceSessionWatch.decide(connection: .disconnected, healthFailure: .pairingRevoked, consecutiveFailures: 1), .stopNeedsApproval)
    }

    func testPairingRetryHonoursCodeExpiry() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(PairingRetry.next(now: start.addingTimeInterval(30), startedAt: start, codeExpiresAt: start.addingTimeInterval(60)), .retry)
        XCTAssertEqual(PairingRetry.next(now: start.addingTimeInterval(60), startedAt: start, codeExpiresAt: start.addingTimeInterval(60)), .codeExpired)
        XCTAssertEqual(PairingRetry.next(now: start.addingTimeInterval(600), startedAt: start, codeExpiresAt: nil), .timedOut)
        XCTAssertEqual(PairingRetry.next(now: start.addingTimeInterval(599), startedAt: start, codeExpiresAt: nil), .retry)
    }

    func testStartRequestFlagIsConsumedOnceAndExpires() {
        let suite = "StartRequestFlagTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = StartRequestFlag(defaults: defaults)
        let now = Date()
        XCTAssertFalse(flag.consume(now: now))
        flag.mark(at: now)
        XCTAssertTrue(flag.consume(now: now.addingTimeInterval(10)))
        XCTAssertFalse(flag.consume(now: now.addingTimeInterval(11)))
        flag.mark(at: now)
        XCTAssertFalse(flag.consume(now: now.addingTimeInterval(StartRequestFlag.validity + 1)))
    }

    func testListedButFoldedGlassesAreNotAvailable() {
        let folded = GlassesDeviceObservation(link: .disconnected, battery: 80)
        XCTAssertFalse(GlassesStateMapper.hasConnectedDevice([folded]))
        XCTAssertEqual(GlassesStateMapper.snapshot(registered: true, devices: [folded]).glasses, .waiting)
        XCTAssertNil(GlassesStateMapper.snapshot(registered: true, devices: [folded]).battery)
        let worn = GlassesDeviceObservation(link: .connected, battery: 72, charging: false)
        XCTAssertTrue(GlassesStateMapper.hasConnectedDevice([folded, worn]))
        XCTAssertEqual(GlassesStateMapper.snapshot(registered: true, devices: [folded, worn]),
                       GlassesSnapshot(glasses: .connected, battery: 72, charging: false))
    }

    func testGlassesMapperRegistrationAndUpdate() {
        XCTAssertEqual(GlassesStateMapper.snapshot(registered: false, devices: []).glasses, .registrationRequired)
        XCTAssertEqual(GlassesStateMapper.snapshot(registered: true, devices: []).glasses, .waiting)
        XCTAssertEqual(GlassesStateMapper.snapshot(
            registered: true, devices: [.init(link: .connected, updateRequired: true)]).glasses, .updateRequired)
        XCTAssertEqual(GlassesStateMapper.snapshot(registered: true, devices: [.init(link: .connecting)]).glasses, .connecting)
    }

    func testSilentWAVHeaderAndSilence() {
        let data = SilentWAV.data(seconds: 0.5, sampleRate: 8_000)
        XCTAssertEqual(data.count, 44 + 8_000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
    }
}
