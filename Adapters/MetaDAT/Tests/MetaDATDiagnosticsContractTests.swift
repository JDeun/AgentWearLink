import AgentWearLinkCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATDiagnosticsContractTests: XCTestCase {
    func testMetaLifecycleDiagnosticNamesCarryOnlySafeMetadata() {
        let recorder = AWLDiagnosticRecorder(capacity: 3)
        let id = InteractionID()
        recorder.record(.init(kind: .metaConnectStarted, generation: 12))
        recorder.record(.init(kind: .metaSessionReady, generation: 12))
        recorder.record(.init(kind: .metaSnapshotRequested, interactionID: id, generation: 12))
        recorder.record(.init(kind: .metaTranscriptAccepted, interactionID: id, generation: 12))

        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(recorder.droppedCount, 1)
        XCTAssertEqual(events.map(\.kind), [
            .metaSessionReady, .metaSnapshotRequested, .metaTranscriptAccepted
        ])
        XCTAssertEqual(events[1].interactionID, id)
        XCTAssertTrue(events.allSatisfy { $0.generation == 12 })
    }
}
