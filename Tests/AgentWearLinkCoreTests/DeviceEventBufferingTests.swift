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

        // bufferingNewest(64) accepts value 64 by dropping value 0. The
        // explicit overload marker then becomes the newest value and drops 1.
        XCTAssertEqual(observed.count, 64)
        XCTAssertEqual(observed.first, .text(interactionID, "2"))

        guard let terminal = observed.last else {
            return XCTFail("Expected terminal overload event")
        }
        guard case let .failed(failedID, .overloaded(message)) = terminal else {
            return XCTFail("Expected overload failure, got \(terminal)")
        }
        XCTAssertEqual(failedID, interactionID)
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
}
