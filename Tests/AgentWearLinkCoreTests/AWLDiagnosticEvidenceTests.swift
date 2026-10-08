import Foundation
import XCTest
@testable import AgentWearLinkCore

final class AWLDiagnosticEvidenceTests: XCTestCase {
    func testExportContainsOnlyAllowlistedFieldsAndLocalCorrelationOrdinal() throws {
        let recorder = AWLDiagnosticRecorder(capacity: 4)
        let id = InteractionID()
        recorder.record(.init(kind: .requestAccepted, interactionID: id, generation: 9))
        recorder.record(.init(kind: .responseCompleted, interactionID: id, attempt: 2))
        recorder.record(.init(kind: .transportRecovered, generation: 3))

        let report = try AWLDiagnosticEvidence.export(from: recorder)
        XCTAssertTrue(report.contains("\"requestAccepted\""))
        XCTAssertTrue(report.contains("\"responseCompleted\""))
        XCTAssertTrue(report.contains("\"interactionOrdinal\" : 1"))
        XCTAssertTrue(report.contains("\"generation\" : 9"))
        XCTAssertFalse(report.contains(id.rawValue.uuidString))
        XCTAssertFalse(report.contains("token"))
        XCTAssertFalse(report.contains("hostname"))
        XCTAssertFalse(report.contains("sessionKey"))
        XCTAssertFalse(report.contains("transcript"))
        XCTAssertFalse(report.contains("image"))
        XCTAssertFalse(report.contains("prompt"))

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        )
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0]["interactionOrdinal"] as? Int, 1)
        XCTAssertEqual(events[1]["interactionOrdinal"] as? Int, 1)
        XCTAssertNil(events[2]["interactionOrdinal"])
    }

    func testExportIsBoundedAndReportsDroppedHistory() throws {
        let recorder = AWLDiagnosticRecorder(capacity: 2)
        recorder.record(.init(kind: .runtimeActivated))
        recorder.record(.init(kind: .runtimeRetired))
        recorder.record(.init(kind: .transportStopped))

        let report = try AWLDiagnosticEvidence.export(
            from: recorder, maximumEvents: 1
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["droppedEventCount"] as? Int, 1)
        XCTAssertEqual(json["isTruncated"] as? Bool, true)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["kind"] as? String, "transportStopped")
    }
}
