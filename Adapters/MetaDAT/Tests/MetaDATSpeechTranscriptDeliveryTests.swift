import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSpeechTranscriptDeliveryTests: XCTestCase {
    private let timestamp = ContinuousClock.now
    private func transcript(_ text: String, final: Bool = true) -> MetaDATTranscript {
        .init(text: text, isFinal: final, confidence: nil)
    }

    func testPartialBurstCannotEvictFinals() async {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 2)
        let first = transcript("first")
        let second = transcript("second")
        delivery.offer(first, receivedAt: timestamp)
        delivery.offer(transcript("partial", final: false), receivedAt: timestamp)
        delivery.offer(second, receivedAt: timestamp)
        for _ in 0..<100 {
            delivery.offer(transcript("new partial", final: false))
        }

        var iterator = delivery.events().makeAsyncIterator()
        let one = await iterator.next()
        let two = await iterator.next()
        XCTAssertEqual(one, .transcript(first, receivedAt: timestamp))
        XCTAssertEqual(two, .transcript(second, receivedAt: timestamp))
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
        delivery.offer(transcript("ok"), receivedAt: timestamp)
        var iterator = delivery.events().makeAsyncIterator()
        let valid = await iterator.next()
        XCTAssertEqual(valid, .transcript(transcript("ok"), receivedAt: timestamp))

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
        fresh.offer(value, receivedAt: timestamp)
        var iterator = fresh.events().makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, .transcript(value, receivedAt: timestamp))
        fresh.cancel()
    }

    func testDedupUsesIngressTimeRatherThanDelayedConsumerTime() async {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 4)
        let dedup = MetaDATFinalTranscriptDeduplicator()
        let phrase = transcript("알프레드, 지금 몇 시야")
        // All callbacks are buffered before consumption. The duplicate was
        // received 100 ms later; the repeated command arrived two seconds later.
        delivery.offer(phrase, receivedAt: timestamp)
        delivery.offer(phrase, receivedAt: timestamp.advanced(by: .milliseconds(100)))
        delivery.offer(phrase, receivedAt: timestamp.advanced(by: .seconds(2)))
        var iterator = delivery.events().makeAsyncIterator()
        var accepted: [Bool] = []
        for _ in 0..<3 {
            guard case let .transcript(value, receivedAt)? = await iterator.next() else {
                return XCTFail("Expected retained final")
            }
            accepted.append(await dedup.accept(
                .init(text: value.text, isFinal: value.isFinal), now: receivedAt
            ))
        }
        XCTAssertEqual(accepted, [true, false, true])
        delivery.cancel()
    }

    func testOverflowSignalsOwnerBeforeConsumerResumesAndOnlyOnce() async {
        let notified = expectation(description: "owner notified independently of consumer")
        notified.assertForOverFulfill = true
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 1, onOverflow: { _ in
            notified.fulfill()
        })
        delivery.offer(transcript("first"))
        var iterator = delivery.events().makeAsyncIterator()
        let admitted = await iterator.next()
        XCTAssertNotNil(admitted)
        // The consumer has read a final but is suspended in a wake gate.
        delivery.offer(transcript("queued"))
        delivery.offer(transcript("overflow"))
        delivery.offer(transcript("late"))
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertFalse(delivery.commitIfHealthy { XCTFail("in-flight final must not escape") })
        let failure = await iterator.next()
        XCTAssertEqual(failure, .failed(.finalTranscriptOverflow))
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testCallbackEvidenceIsIndependentOfPartialEvictionAndConsumer() async {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 1)
        let time = ContinuousClock.now
        delivery.offer(transcript("final"), receivedAt: time)
        // Buffer is full of finals; both partials are discarded, but their
        // receipt is still evidence of the upstream callback path.
        delivery.offer(transcript("partial", final: false), receivedAt: time.advanced(by: .seconds(1)))
        delivery.offer(transcript("", final: false), receivedAt: time.advanced(by: .seconds(2)))
        let health = delivery.health(sessionStarted: true, phase: .started)
        XCTAssertTrue(health.isSDKReady)
        XCTAssertEqual(health.lastCallbackAt, time.advanced(by: .seconds(2)))
        XCTAssertEqual(health.lastNonEmptyCallbackAt, time.advanced(by: .seconds(1)))
        XCTAssertEqual(health.callbackEvidence(now: time.advanced(by: .seconds(2)), freshness: .seconds(1)), .recentNonEmptyCallback)
        delivery.resetCallbackEvidence()
        XCTAssertEqual(delivery.health(sessionStarted: true, phase: .started).callbackEvidence(freshness: .seconds(1)), .notObserved)
        // Clearing evidence must not clear an admitted final.
        var iterator = delivery.events().makeAsyncIterator()
        let final = await iterator.next()
        XCTAssertEqual(final, .transcript(transcript("final"), receivedAt: time))
        delivery.cancel()
        XCTAssertFalse(delivery.health(sessionStarted: true, phase: .started).isSDKReady)
    }

    func testOverflowImmediatelyInvalidatesSDKReadiness() {
        let delivery = MetaDATSpeechTranscriptDelivery(limit: 1)
        delivery.offer(transcript("one"))
        XCTAssertTrue(delivery.health(sessionStarted: true, phase: .started).isSDKReady)
        delivery.offer(transcript("two"))
        let health = delivery.health(sessionStarted: true, phase: .started)
        XCTAssertFalse(health.isSDKReady)
        XCTAssertEqual(health.callbackEvidence(freshness: .seconds(1)), .unavailable)
    }
}
