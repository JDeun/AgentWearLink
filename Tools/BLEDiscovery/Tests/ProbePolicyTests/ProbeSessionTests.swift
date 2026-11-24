import Foundation
import XCTest
@testable import ProbePolicy

final class ProbeSessionTests: XCTestCase {
    func testExplicitFilterIsRequiredAndValidated() {
        XCTAssertNil(ServiceFilter.normalized(""))
        XCTAssertNil(ServiceFilter.normalized("not-a-service"))
        XCTAssertNil(ServiceFilter.normalized("18G0"))
        XCTAssertEqual(ServiceFilter.normalized(" 180f "), "180F")
        XCTAssertEqual(ServiceFilter.normalized("1234abcd"), "1234ABCD")
        XCTAssertEqual(ServiceFilter.normalized("12345678-1234-1234-1234-123456789abc"),
                       "12345678-1234-1234-1234-123456789ABC")
    }

    func testNoObservationBeforeStartOrFromStaleRun() {
        var session = ProbeSession()
        let old = UUID(), fresh = UUID(), device = UUID()
        XCTAssertTrue(session.begin(token: old))
        XCTAssertFalse(session.begin(token: fresh))
        XCTAssertEqual(session.record(token: old, peripheralID: device,
                                      observation: ProbeObservation()), .ignored)
        XCTAssertTrue(session.startScan(token: old))
        XCTAssertTrue(session.finish(token: old, status: .userStopped))
        XCTAssertTrue(session.begin(token: fresh))
        XCTAssertTrue(session.startScan(token: fresh))
        XCTAssertEqual(session.record(token: old, peripheralID: device,
                                      observation: ProbeObservation()), .ignored)
        XCTAssertFalse(session.finish(token: old, status: .completed))
        XCTAssertEqual(session.status, .scanning)
        XCTAssertTrue(session.candidates.isEmpty)
    }

    func testDeduplicationAndCategoricalEvidence() {
        var session = ProbeSession()
        let token = UUID(), device = UUID()
        XCTAssertTrue(session.begin(token: token))
        XCTAssertTrue(session.startScan(token: token))
        XCTAssertFalse(session.finish(token: token, status: .completed))
        XCTAssertTrue(session.markScanRequested(token: token))
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(localName: "PRIVATE DEVICE",
                                          systemConnectedSnapshot: true)), .accepted)
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(advertisement: true,
                                          serviceAdvertised: true, connectable: true)), .accepted)
        XCTAssertEqual(session.candidates.count, 1)
        XCTAssertFalse(session.confirm(id: 1, independentlyIdentified: true))
        XCTAssertTrue(session.finish(token: token, status: .completed))
        XCTAssertFalse(session.confirm(id: 1, independentlyIdentified: false))
        XCTAssertFalse(session.confirm(id: 2, independentlyIdentified: true))
        XCTAssertTrue(session.confirm(id: 1, independentlyIdentified: true))
        XCTAssertTrue(session.report.contains("system-connected-at-start=yes"))
        XCTAssertTrue(session.report.contains("requested-service-advertised=yes"))
        XCTAssertTrue(session.report.contains("l2cap=not-tested"))
        XCTAssertTrue(session.report.contains("companion-authorization=not-tested"))
        XCTAssertFalse(session.report.contains("PRIVATE DEVICE"))
        XCTAssertFalse(session.report.contains(device.uuidString))
        XCTAssertFalse(session.report.contains(token.uuidString))
        session.revokeConfirmation()
        XCTAssertTrue(session.report.contains("owner-confirmed=no"))
    }

    func testCapacityAndAbortClearAllCandidates() {
        var session = ProbeSession()
        let token = UUID()
        XCTAssertTrue(session.begin(token: token))
        XCTAssertTrue(session.startScan(token: token))
        for _ in 0..<ProbeSession.candidateLimit {
            XCTAssertEqual(session.record(token: token, peripheralID: UUID(),
                                          observation: ProbeObservation(localName: "private", systemConnectedSnapshot: true)), .accepted)
        }
        XCTAssertEqual(session.record(token: token, peripheralID: UUID(),
                                      observation: ProbeObservation(systemConnectedSnapshot: true)), .capacityExceeded)
        XCTAssertEqual(session.candidates.count, ProbeSession.candidateLimit)
        XCTAssertTrue(session.finish(token: token, status: .candidateLimit))
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertFalse(session.confirm(id: 1, independentlyIdentified: true))
    }

    func testPermissionTimeoutAndBackgroundNeverClaimCompleted() {
        var session = ProbeSession()
        let token = UUID()
        XCTAssertTrue(session.begin(token: token))
        XCTAssertFalse(session.finish(token: token, status: .completed))
        XCTAssertTrue(session.finish(token: token, status: .initializationTimedOut))
        XCTAssertTrue(session.report.contains("owner-confirmed=no"))
        session.clear()
        XCTAssertEqual(session.status, .idle)
        XCTAssertNil(session.token)
        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertTrue(session.report.contains("gatt-characteristics=not-tested"))
    }

    func testSystemOnlyMatchDoesNotAssertAdvertisementFields() {
        var session = ProbeSession()
        let token = UUID(), device = UUID()
        XCTAssertTrue(session.begin(token: token))
        XCTAssertTrue(session.startScan(token: token))
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(advertisement: true)), .ignored)
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(systemConnectedSnapshot: true)), .accepted)
        XCTAssertFalse(session.finish(token: token, status: .completed))
        XCTAssertTrue(session.markScanRequested(token: token))
        XCTAssertTrue(session.finish(token: token, status: .completed))
        XCTAssertTrue(session.confirm(id: 1, independentlyIdentified: true))
        XCTAssertTrue(session.report.contains("advertisement-callback=no"))
        XCTAssertTrue(session.report.contains("requested-service-advertised=not-observed"))
        XCTAssertTrue(session.report.contains("requested-service-data-present=not-observed"))
    }

    func testElapsedEvidenceAndGateClassification() {
        var session = ProbeSession()
        let token = UUID(), device = UUID()
        XCTAssertTrue(session.begin(token: token))
        XCTAssertTrue(session.startScan(token: token))
        XCTAssertTrue(session.markScanRequested(token: token, elapsedMS: 2400))
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(), elapsedMS: 2500), .ignored)
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(advertisement: true),
                                      elapsedMS: 2700), .accepted)
        XCTAssertEqual(session.record(token: token, peripheralID: device,
                                      observation: ProbeObservation(advertisement: true),
                                      elapsedMS: 2800), .accepted)
        XCTAssertTrue(session.finish(token: token, status: .completed, elapsedMS: 15020))
        XCTAssertTrue(session.report.contains("gate-a-observation=inconclusive-identity-unconfirmed"))
        XCTAssertTrue(session.report.contains("confirmed-first-callback-from-request-ms=not-observed"))
        XCTAssertTrue(session.confirm(id: 1, independentlyIdentified: true))
        XCTAssertTrue(session.report.contains("gate-a-observation=owner-confirmed-advertisement-callback"))
        XCTAssertTrue(session.report.contains("run-elapsed-ms=15020"))
        XCTAssertTrue(session.report.contains("scan-request-to-finish-ms=12620"))
        XCTAssertTrue(session.report.contains("confirmed-first-callback-from-request-ms=300"))
        XCTAssertTrue(session.report.contains("transport-feasibility=not-established"))
        session.revokeConfirmation()
        XCTAssertTrue(session.report.contains("confirmed-first-callback-from-request-ms=not-observed"))
    }

    func testEmptyAndAbortedScansRemainInconclusive() {
        var session = ProbeSession()
        let token = UUID()
        XCTAssertTrue(session.report.contains("gate-a-observation=not-run"))
        XCTAssertTrue(session.begin(token: token))
        XCTAssertTrue(session.startScan(token: token))
        XCTAssertTrue(session.markScanRequested(token: token, elapsedMS: 100))
        XCTAssertTrue(session.finish(token: token, status: .completed, elapsedMS: 15000))
        XCTAssertTrue(session.report.contains("gate-a-observation=inconclusive-no-match"))
        let fresh = UUID()
        XCTAssertTrue(session.begin(token: fresh))
        XCTAssertTrue(session.finish(token: fresh, status: .poweredOff, elapsedMS: 25))
        XCTAssertTrue(session.report.contains("gate-a-observation=inconclusive-aborted"))
        XCTAssertTrue(session.report.contains("scan-request-to-finish-ms=not-observed"))
        XCTAssertTrue(session.report.contains("transport-feasibility=not-established"))
    }

    func testNoIdentityOrCapabilityInferredFromMultipleMatches() {
        var session = ProbeSession()
        let token = UUID()
        XCTAssertTrue(session.begin(token: token))
        XCTAssertTrue(session.startScan(token: token))
        XCTAssertTrue(session.markScanRequested(token: token))
        for _ in 0..<2 {
            _ = session.record(token: token, peripheralID: UUID(),
                               observation: ProbeObservation(localName: "Same name",
                                                             advertisement: true))
        }
        XCTAssertTrue(session.finish(token: token, status: .completed))
        XCTAssertEqual(session.candidates.count, 2)
        XCTAssertNil(session.confirmedID)
        XCTAssertTrue(session.report.contains("owner-confirmed=no"))
        XCTAssertTrue(session.report.contains("advertisement-callback=not-observed"))
    }
}
