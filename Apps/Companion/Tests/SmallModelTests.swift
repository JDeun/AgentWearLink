import XCTest

final class SmallModelTests: XCTestCase {
    func testFingerprintFormats() {
        let id = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
        XCTAssertEqual(DeviceFingerprint.short(id), "A1B2-C3D4")
        XCTAssertEqual(DeviceFingerprint.grouped("a1b2c3d4e5"), "a1b2 c3d4 e5")
        XCTAssertEqual(DeviceFingerprint.short("abc"), "ABC")
    }

    func testLatencyIsSpeechEndToFirstReplyText() throws {
        var tracker = TurnLatencyTracker()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNil(tracker.replyText(replyID: "unsolicited", at: start))
        tracker.requestForwarded(at: start)
        XCTAssertEqual(try XCTUnwrap(tracker.replyText(replyID: "r1", at: start.addingTimeInterval(4.2))), 4.2, accuracy: 0.001)
        XCTAssertNil(tracker.replyText(replyID: "r1", at: start.addingTimeInterval(5)))
    }

    func testRecoveryBackoffCapsAtLastStep() {
        XCTAssertEqual(RecoveryPolicy.delay(afterFailedAttempt: 0), 5)
        XCTAssertEqual(RecoveryPolicy.delay(afterFailedAttempt: 2), 30)
        XCTAssertEqual(RecoveryPolicy.delay(afterFailedAttempt: 99), 60)
        XCTAssertEqual(RecoveryPolicy.delay(afterFailedAttempt: -1), 5)
    }

    func testActivityLogIsBounded() {
        var log = ActivityLog(capacity: 2)
        log.append("a", at: Date(timeIntervalSince1970: 0))
        log.append("b", at: Date(timeIntervalSince1970: 1))
        log.append("c", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(log.entries.map(\.message), ["b", "c"])
        XCTAssertEqual(log.export { "\(Int($0.timeIntervalSince1970))" }, "1 b\n2 c")
    }

    func testSetupProgressOrderAndSkipping() {
        var progress = SetupProgress()
        XCTAssertEqual(progress.current, .metaRegistration)
        XCTAssertFalse(progress.skip(.metaRegistration))
        progress.complete(.metaRegistration)
        progress.complete(.microphone)
        XCTAssertTrue(progress.skip(.tailscale))
        XCTAssertEqual(progress.current, .gateway)
        XCTAssertEqual(progress.position, 4)
        XCTAssertEqual(progress.state(of: .tailscale), .done)
        XCTAssertEqual(progress.state(of: .gateway), .current)
        XCTAssertEqual(progress.state(of: .practice), .upcoming)
        progress.complete(.gateway)
        XCTAssertTrue(progress.skip(.practice))
        XCTAssertTrue(progress.isFinished)
        progress.restartGatewayApproval()
        XCTAssertEqual(progress.current, .gateway)
    }
}
