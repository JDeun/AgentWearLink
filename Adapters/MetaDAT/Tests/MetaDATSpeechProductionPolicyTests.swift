import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechProductionPolicyTests: XCTestCase {
    func testPartialThenFinalThenDuplicateProducesExactlyOneInteraction() async {
        let deduplicator = MetaDATFinalTranscriptDeduplicator()
        let filter = MetaDATFinalTranscriptFilter()
        let interactionID = InteractionID()

        let partial = MetaDATDedupTranscript(
            text: "turn left",
            isFinal: false
        )
        let partialAccepted = await deduplicator.accept(partial)
        XCTAssertFalse(partialAccepted)
        XCTAssertNil(
            filter.event(
                for: .init(text: partial.text, isFinal: partial.isFinal),
                interactionID: interactionID
            )
        )

        let final = MetaDATDedupTranscript(
            text: "turn left",
            isFinal: true
        )
        let finalAccepted = await deduplicator.accept(final)
        XCTAssertTrue(finalAccepted)

        let event = filter.event(
            for: .init(text: final.text, isFinal: final.isFinal),
            interactionID: interactionID
        )
        guard case let .text(id, text)? = event else {
            return XCTFail("expected one normalized final transcript")
        }
        XCTAssertEqual(id, interactionID)
        XCTAssertEqual(text, "turn left")

        let duplicateAccepted = await deduplicator.accept(final)
        XCTAssertFalse(duplicateAccepted)
    }

    func testWhitespaceOnlyFinalIsNeverForwarded() async {
        let deduplicator = MetaDATFinalTranscriptDeduplicator()
        let filter = MetaDATFinalTranscriptFilter()
        let transcript = MetaDATDedupTranscript(
            text: "   \n",
            isFinal: true
        )

        let accepted = await deduplicator.accept(transcript)
        XCTAssertFalse(accepted)
        XCTAssertNil(
            filter.event(
                for: .init(text: transcript.text, isFinal: transcript.isFinal),
                interactionID: InteractionID()
            )
        )
    }
}
