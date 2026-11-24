import XCTest
@testable import AgentWearLinkCore

final class DeviceEventBufferingTests: XCTestCase {
    func testMockDeviceEventStreamFailsFastOnSlowConsumerOverflow() async {
        let device = MockDeviceAdapter()
        let stream = device.events()
        let interactionID = InteractionID()

        // Do not consume while producing: the 65th value must exceed the
        // production-facing 64-event buffer deterministically.
        for index in 0...64 {
            await device.emit(.text(interactionID, String(index)))
        }

        var iterator = stream.makeAsyncIterator()
        var observed: [InteractionEvent] = []
        while let event = await iterator.next() {
            observed.append(event)
        }

        // A missing control/text event invalidates the entire pending sequence.
        XCTAssertEqual(observed.count, 1)

        guard let terminal = observed.last else {
            return XCTFail("Expected terminal overload event")
        }
        guard case let .failed(failedID, .overloaded(message)) = terminal else {
            return XCTFail("Expected overload failure, got \(terminal)")
        }
        XCTAssertNil(failedID)
        XCTAssertTrue(message.contains("buffer"))

        // Overflow retires only the affected subscription. A later runtime
        // generation can install a fresh bounded stream.
        let replacement = device.events()
        var replacementIterator = replacement.makeAsyncIterator()
        await device.emit(.text(interactionID, "recovered"))
        let recovered = await replacementIterator.next()
        XCTAssertEqual(recovered, .text(interactionID, "recovered"))
        await device.disconnect()
    }

    func testFIFOAndReplacementDiscardPendingOldGeneration() async {
        let source = BoundedDeviceEventSource(bufferLimit: 3)
        let id = InteractionID()
        let first = source.stream()
        let old = source.currentGeneration()
        source.yield(.sessionStarted(id), generation: old)
        let replacement = source.stream()
        var oldIterator = first.makeAsyncIterator()
        let retired = await oldIterator.next()
        XCTAssertNil(retired)

        source.finish(generation: old)
        source.yield(.text(id, "stale"), generation: old)
        source.yield(.sessionStarted(id))
        source.yield(.text(id, "fresh"))
        source.yield(.sessionEnded(id))
        var iterator = replacement.makeAsyncIterator()
        let start = await iterator.next()
        let text = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(start, .sessionStarted(id))
        XCTAssertEqual(text, .text(id, "fresh"))
        XCTAssertEqual(end, .sessionEnded(id))
        source.finish()
        let terminal = await iterator.next()
        XCTAssertNil(terminal)
    }

    func testConcurrentProducersOverflowExactlyOnceAcrossInteractions() async {
        let source = BoundedDeviceEventSource(bufferLimit: 4)
        let stream = source.stream()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { source.yield(.sessionStarted(InteractionID())) }
            }
        }
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        guard case .failed(nil, .overloaded) = event else {
            return XCTFail("Expected global overload, got \(String(describing: event))")
        }
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testCancellationRetiresOnlyItsMailbox() async {
        let source = BoundedDeviceEventSource(bufferLimit: 2)
        let first = source.stream()
        let oldTask = Task {
            var iterator = first.makeAsyncIterator()
            return await iterator.next()
        }
        let replacement = source.stream()
        oldTask.cancel()
        let retired = await oldTask.value
        XCTAssertNil(retired)

        let id = InteractionID()
        source.yield(.sessionStarted(id))
        var iterator = replacement.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertEqual(next, .sessionStarted(id))
        source.finish()
    }
}
