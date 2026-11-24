import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechTranscriptDeliveryTests: XCTestCase {
    private func transcript(_ text: String, final: Bool = true) -> MetaDATTranscript {
        .init(text: text, isFinal: final, confidence: nil)
    }

    func testPartialBurstCannotEvictFinals() async {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 2)
        let first = transcript("first")
        let second = transcript("second")
        delivery.offer(first)
        delivery.offer(transcript("partial", final: false))
        delivery.offer(second)
        for _ in 0..<100 {
            delivery.offer(transcript("new partial", final: false))
        }

        var iterator = delivery.events().makeAsyncIterator()
        let one = await iterator.next()
        let two = await iterator.next()
        XCTAssertEqual(one, .transcript(first))
        XCTAssertEqual(two, .transcript(second))
        delivery.cancel()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testFinalSaturationDiscardsPendingAndFailsOnce() async {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 2)
        delivery.offer(transcript("first"))
        delivery.offer(transcript("second"))
        delivery.offer(transcript("overflow"))
        delivery.offer(transcript("ignored", final: false))
        delivery.offer(transcript("ignored final"))
        XCTAssertFalse(delivery.commitIfHealthy { XCTFail("must not commit a stale final") })

        var iterator = delivery.events().makeAsyncIterator()
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .failed(.finalTranscriptOverflow))
        XCTAssertNil(end)
    }

    func testOversizedPartialIsIgnoredAndOversizedFinalFailsClosed() async {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 2, maximumTranscriptBytes: 4)
        delivery.offer(transcript("알프레드", final: false))
        delivery.offer(transcript("ok"))
        var iterator = delivery.events().makeAsyncIterator()
        let valid = await iterator.next()
        XCTAssertEqual(valid, .transcript(transcript("ok")))

        delivery.offer(transcript("알프레드"))
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .failed(.finalTranscriptOverflow))
        XCTAssertNil(end)
    }

    func testCancellationIsIsolatedToItsOwnSubscription() async {
        let old = MetaDATSpeechTranscriptDelivery(limit: 1)
        let fresh = MetaDATSpeechTranscriptDelivery(limit: 1)
        let oldTask = Task {
            var iterator = old.events().makeAsyncIterator()
            return await iterator.next()
        }
        oldTask.cancel()
        let retired = await oldTask.value
        XCTAssertNil(retired)

        let value = transcript("fresh")
        fresh.offer(value)
        var iterator = fresh.events().makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, .transcript(value))
        fresh.cancel()
    }
}
