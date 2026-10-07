import Foundation
import XCTest
@testable import AgentWearLinkCore

final class AWLDiagnosticsTests: XCTestCase {
    func testBoundedRecorderEvictsOldestWithoutUnboundedGrowth() {
        let recorder = AWLDiagnosticRecorder(capacity: 2)
        recorder.record(.init(kind: .runtimeActivated, generation: 1))
        recorder.record(.init(kind: .runtimeRetired, generation: 1))
        recorder.record(.init(kind: .transportRetry, generation: 2, attempt: 3))
        XCTAssertEqual(recorder.snapshot().map(\.kind), [.runtimeRetired, .transportRetry])
        XCTAssertEqual(recorder.droppedCount, 1)
        XCTAssertEqual(recorder.drain().count, 2)
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    func testDiagnosticsCannotContainPromptSecretOrPrivateMedia() async {
        let recorder = AWLDiagnosticRecorder()
        let agent = MockAgentAdapter()
        let coordinator = InteractionCoordinator(
            agent: agent,
            maximumRequestTextBytes: 3,
            diagnostics: recorder
        ) { _ in }
        let id = InteractionID()
        await coordinator.handle(.text(id, "SECRET-1234 prompt and private image"))
        let events = recorder.snapshot()
        XCTAssertEqual(events.map(\.kind), [.requestOversize])
        XCTAssertEqual(events.first?.interactionID, id)
        let description = String(reflecting: events)
        XCTAssertFalse(description.contains("SECRET-1234"))
        XCTAssertFalse(description.contains("private image"))
    }

    func testGenerationLifecycleRecordsOnlyStructuredMetadata() async {
        let recorder = AWLDiagnosticRecorder()
        let coordinator = InteractionCoordinator(
            agent: MockAgentAdapter(),
            diagnostics: recorder
        ) { _ in }
        await coordinator.activate(runtimeGeneration: 42)
        await coordinator.deactivate(runtimeGeneration: 42)
        XCTAssertEqual(
            recorder.snapshot().map(\.kind),
            [.runtimeActivated, .runtimeRetired]
        )
        XCTAssertEqual(recorder.snapshot().map(\.generation), [42, 42])
    }
}
