import Foundation
import XCTest
@testable import LabTransport

final class LabDriverLifecycleTests: XCTestCase {
    func testCentralMockSequenceAndExplicitConfirmation() {
        let token = UUID()
        var life = LabDriverLifecycle()
        XCTAssertTrue(life.begin(generation: token, stage: .centralInit, nowMS: 100))
        XCTAssertFalse(life.begin(generation: UUID(), stage: .serverInit, nowMS: 101))
        XCTAssertEqual(life.deadline, 15_100)
        XCTAssertFalse(life.move(generation: token, to: .connecting, nowMS: 200))
        XCTAssertTrue(life.move(generation: token, to: .scanning, nowMS: 300))
        XCTAssertEqual(life.deadline, 5_300)
        XCTAssertFalse(life.move(generation: token, to: .scanning, nowMS: 1_000))
        XCTAssertFalse(life.move(generation: token, to: .confirmFixture, nowMS: 1_000))
        XCTAssertEqual(life.tick(generation: token, nowMS: 5_299, hasCandidate: true), .proceed)
        XCTAssertEqual(life.tick(generation: token, nowMS: 5_300, hasCandidate: true), .confirmFixture)
        XCTAssertEqual(life.deadline, 35_300)
        XCTAssertFalse(life.move(generation: token, to: .opening, nowMS: 5_301))
        XCTAssertTrue(life.move(generation: token, to: .connecting, nowMS: 5_301))
        XCTAssertNil(life.deadline) // LabSession now owns phase timeouts.
        for (i, stage) in [LabDriverStage.service, .marker, .markerRead, .opening, .transfer].enumerated() {
            XCTAssertTrue(life.move(generation: token, to: stage, nowMS: UInt64(5_302+i)))
            XCTAssertFalse(life.move(generation: token, to: stage, nowMS: UInt64(5_302+i)))
        }
        XCTAssertEqual(life.stage, .transfer)
        XCTAssertNotNil(life.retire(generation: token))
        XCTAssertNil(life.retire(generation: token))
        XCTAssertEqual(life.stage, .finished)
    }

    func testScanNoCandidateAndConfirmationExpiry() {
        var life = LabDriverLifecycle()
        let token = UUID()
        XCTAssertTrue(life.begin(generation: token, stage: .centralInit, nowMS: 0))
        XCTAssertTrue(life.move(generation: token, to: .scanning, nowMS: 1))
        XCTAssertEqual(life.tick(generation: token, nowMS: 5_001, hasCandidate: false), .terminate("no-fixture"))
        XCTAssertFalse(life.move(generation: token, to: .connecting, nowMS: 5_001))
        XCTAssertNotNil(life.retire(generation: token))
        let fresh = UUID()
        XCTAssertTrue(life.begin(generation: fresh, stage: .centralInit, nowMS: 6_000))
        XCTAssertTrue(life.move(generation: fresh, to: .scanning, nowMS: 6_001))
        XCTAssertEqual(life.tick(generation: fresh, nowMS: 11_001, hasCandidate: true), .confirmFixture)
        XCTAssertFalse(life.move(generation: fresh, to: .connecting, nowMS: 41_001))
        XCTAssertEqual(life.tick(generation: fresh, nowMS: 41_001, hasCandidate: true), .terminate("setup-timeout"))
    }

    func testServerSequenceDoesNotTreatPublicationAsOpenOrPermitUnconfirmedIO() {
        let token = UUID()
        var life = LabDriverLifecycle()
        XCTAssertTrue(life.begin(generation: token, stage: .serverInit, nowMS: 0))
        XCTAssertFalse(life.move(generation: token, to: .confirmIncoming, nowMS: 1))
        for (i, stage) in [LabDriverStage.publishing, .adding, .advertising, .listening].enumerated() {
            XCTAssertTrue(life.move(generation: token, to: stage, nowMS: UInt64(1+i)))
            XCTAssertFalse(life.move(generation: token, to: stage, nowMS: UInt64(1+i)))
        }
        XCTAssertEqual(life.deadline, 90_004)
        XCTAssertFalse(life.move(generation: token, to: .transfer, nowMS: 5))
        XCTAssertTrue(life.move(generation: token, to: .confirmIncoming, nowMS: 6))
        XCTAssertNil(life.deadline)
        XCTAssertTrue(life.move(generation: token, to: .transfer, nowMS: 7))
        XCTAssertTrue(life.move(generation: token, to: .draining, nowMS: 8))
        XCTAssertEqual(life.deadline, 2_008)
        XCTAssertFalse(life.move(generation: token, to: .transfer, nowMS: 9))
        XCTAssertFalse(life.move(generation: token, to: .draining, nowMS: 100))
        XCTAssertEqual(life.tick(generation: token, nowMS: 2_007, hasCandidate: false), .proceed)
        XCTAssertEqual(life.tick(generation: token, nowMS: 2_008, hasCandidate: false), .terminate("responder-drain-deadline"))
        XCTAssertNotNil(life.retire(generation: token))
    }

    func testCancelledGenerationCannotAdvanceOrExpireReplacement() {
        var life = LabDriverLifecycle()
        let old = UUID(), fresh = UUID()
        XCTAssertTrue(life.begin(generation: old, stage: .serverInit, nowMS: 0))
        XCTAssertTrue(life.move(generation: old, to: .publishing, nowMS: 1))
        var retired = life.retire(generation: old)!
        XCTAssertTrue(life.begin(generation: fresh, stage: .centralInit, nowMS: 2))
        XCTAssertEqual(life.tick(generation: old, nowMS: UInt64.max, hasCandidate: true), .ignored)
        XCTAssertFalse(life.move(generation: old, to: .adding, nowMS: 3))
        XCTAssertNil(life.retire(generation: old))
        XCTAssertTrue(retired.consume(.publishing))
        XCTAssertFalse(retired.consume(.publishing))
        XCTAssertEqual(life.stage, .centralInit)
        XCTAssertEqual(life.generation, fresh)
        XCTAssertEqual(life.deadline, 15_002)
    }

    func testLateServerCleanupOnlyForOnePendingOperation() {
        for target in [LabDriverStage.publishing, .adding, .advertising, .listening] {
            var life = LabDriverLifecycle()
            let token = UUID()
            XCTAssertTrue(life.begin(generation: token, stage: .serverInit, nowMS: 0))
            for (i, stage) in [LabDriverStage.publishing, .adding, .advertising, .listening].enumerated() {
                XCTAssertTrue(life.move(generation: token, to: stage, nowMS: UInt64(i+1)))
                if stage == target { break }
            }
            var retired = life.retire(generation: token)!
            for stage in [LabDriverStage.publishing, .adding, .advertising] where stage != target {
                XCTAssertFalse(retired.consume(stage))
            }
            if target == .listening {
                XCTAssertFalse(retired.consume(.listening))
            } else {
                XCTAssertTrue(retired.isPending(target))
                XCTAssertTrue(retired.consume(target))
                XCTAssertFalse(retired.consume(target))
            }
        }
    }

    func testDeadlinesAndClockRegressionCannotBeExtendedByWrongCallbacks() {
        let token = UUID()
        var life = LabDriverLifecycle()
        XCTAssertTrue(life.begin(generation: token, stage: .serverInit, nowMS: 100))
        XCTAssertTrue(life.move(generation: token, to: .publishing, nowMS: 200))
        XCTAssertFalse(life.move(generation: token, to: .adding, nowMS: 199))
        XCTAssertEqual(life.tick(generation: token, nowMS: 199, hasCandidate: false), .terminate("clockRegression"))
        XCTAssertFalse(life.move(generation: token, to: .adding, nowMS: 15_100))
        XCTAssertEqual(life.tick(generation: token, nowMS: 15_100, hasCandidate: false), .terminate("setup-timeout"))
        XCTAssertNotNil(life.retire(generation: token))
        let near = UUID()
        XCTAssertTrue(life.begin(generation: near, stage: .centralInit, nowMS: UInt64.max - 1))
        XCTAssertEqual(life.deadline, UInt64.max)
        XCTAssertEqual(life.tick(generation: near, nowMS: UInt64.max, hasCandidate: false), .terminate("setup-timeout"))
    }

    func testDeliveredCallbackCannotBeRetiredAsPendingAtDeadline() {
        for target in [LabDriverStage.publishing, .adding, .advertising] {
            var life = LabDriverLifecycle()
            let token = UUID()
            XCTAssertTrue(life.begin(generation: token, stage: .serverInit, nowMS: 0))
            for (i, stage) in [LabDriverStage.publishing, .adding, .advertising].enumerated() {
                XCTAssertTrue(life.move(generation: token, to: stage, nowMS: UInt64(i+1)))
                if stage == target { break }
                XCTAssertTrue(life.acknowledgeServerOperation(generation: token, stage: stage))
            }
            XCTAssertFalse(life.acknowledgeServerOperation(generation: UUID(), stage: target))
            XCTAssertTrue(life.acknowledgeServerOperation(generation: token, stage: target))
            XCTAssertFalse(life.acknowledgeServerOperation(generation: token, stage: target))
            XCTAssertEqual(life.tick(generation: token, nowMS: 15_000, hasCandidate: false), .terminate("setup-timeout"))
            var retired = life.retire(generation: token)!
            XCTAssertFalse(retired.consume(target))
        }
    }

    func testDisconnectAdmittedOnlyForActiveCentralStages() {
        for stage in [LabDriverStage.idle, .centralInit, .scanning, .confirmFixture, .finished, .publishing, .listening] {
            XCTAssertFalse(stage.acceptsCentralDisconnect)
        }
        for stage in [LabDriverStage.connecting, .service, .marker, .markerRead, .opening, .transfer, .draining] {
            XCTAssertTrue(stage.acceptsCentralDisconnect)
        }
    }
}
