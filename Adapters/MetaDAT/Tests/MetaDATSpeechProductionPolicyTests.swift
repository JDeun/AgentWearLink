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

    func testIntentionalRepeatedFinalAfterWindowIsAccepted() async {
        let dedup = MetaDATFinalTranscriptDeduplicator(duplicateWindow: .seconds(1))
        let start = ContinuousClock.now
        let phrase = MetaDATDedupTranscript(text: "알프레드, 지금 몇 시야", isFinal: true)
        let first = await dedup.accept(phrase, now: start)
        let immediate = await dedup.accept(phrase, now: start.advanced(by: .milliseconds(100)))
        let laterDuplicate = await dedup.accept(phrase, now: start.advanced(by: .milliseconds(900)))
        let repeated = await dedup.accept(phrase, now: start.advanced(by: .seconds(1)))
        XCTAssertTrue(first)
        XCTAssertFalse(immediate)
        XCTAssertFalse(laterDuplicate)
        XCTAssertTrue(repeated)
    }

    func testDifferentFinalBreaksConsecutiveDeduplication() async {
        let dedup = MetaDATFinalTranscriptDeduplicator()
        let time = ContinuousClock.now
        let a = MetaDATDedupTranscript(text: "A", isFinal: true)
        let b = MetaDATDedupTranscript(text: "B", isFinal: true)
        let first = await dedup.accept(a, now: time)
        let different = await dedup.accept(b, now: time)
        let repeated = await dedup.accept(a, now: time)
        XCTAssertTrue(first)
        XCTAssertTrue(different)
        XCTAssertTrue(repeated)
    }

    func testLongLivedSessionDoesNotRememberEveryUniqueFinal() async {
        let dedup = MetaDATFinalTranscriptDeduplicator()
        let time = ContinuousClock.now
        let first = MetaDATDedupTranscript(text: "original", isFinal: true)
        let accepted = await dedup.accept(first, now: time)
        XCTAssertTrue(accepted)
        for index in 0..<2048 {
            let unique = await dedup.accept(
                .init(text: String(index), isFinal: true), now: time
            )
            XCTAssertTrue(unique)
        }
        let repeated = await dedup.accept(first, now: time)
        XCTAssertTrue(repeated)
    }

    func testResetAndOversizedFinalDoNotRetainPriorText() async {
        let dedup = MetaDATFinalTranscriptDeduplicator(maximumCachedUTF8Bytes: 4)
        let time = ContinuousClock.now
        let short = MetaDATDedupTranscript(text: "hi", isFinal: true)
        let long = MetaDATDedupTranscript(text: "알프레드", isFinal: true)
        let first = await dedup.accept(short, now: time)
        XCTAssertTrue(first)
        await dedup.reset()
        let afterReset = await dedup.accept(short, now: time)
        XCTAssertTrue(afterReset)
        let oversized = await dedup.accept(long, now: time)
        let oversizedRepeated = await dedup.accept(long, now: time)
        let shortAgain = await dedup.accept(short, now: time)
        XCTAssertTrue(oversized)
        XCTAssertTrue(oversizedRepeated)
        XCTAssertTrue(shortAgain)
    }
}
