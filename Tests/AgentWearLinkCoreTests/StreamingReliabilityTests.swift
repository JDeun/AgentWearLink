import Foundation
import XCTest
@testable import AgentWearLinkCore

final class StreamingReliabilityTests: XCTestCase {
    func testCancelledChannelConsumerReturnsNilAndDoesNotConsumeNextValue() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 2)

        let cancelledConsumer = Task { await channel.next() }
        await Task.yield()
        cancelledConsumer.cancel()

        let cancelledValue = await cancelledConsumer.value
        XCTAssertNil(cancelledValue)

        await channel.send(42)
        let nextValue = await channel.next()
        XCTAssertEqual(nextValue, 42)
    }

    func testSSEParserRejectsUnterminatedOversizedLine() {
        var parser = SSEParser(maximumBufferedBytes: 16)

        XCTAssertThrowsError(
            try parser.append(Data(String(repeating: "x", count: 17).utf8))
        ) { error in
            XCTAssertEqual(
                error as? SSEParserError,
                .pendingEventTooLarge(actual: 17, maximum: 16)
            )
        }
    }

    func testSSEParserBoundsMultiLinePendingEvent() throws {
        var parser = SSEParser(maximumBufferedBytes: 20)

        _ = try parser.append(Data("data: 1234\n".utf8))

        XCTAssertThrowsError(
            try parser.append(Data("data: 567890\n".utf8))
        )
    }

    func testSSEParserCanContinueAfterLimitViolation() throws {
        var parser = SSEParser(maximumBufferedBytes: 16)

        XCTAssertThrowsError(
            try parser.append(Data(String(repeating: "x", count: 17).utf8))
        )

        let events = try parser.append(Data("data: ok\n\n".utf8))
        XCTAssertEqual(events, [ServerSentEvent(data: "ok")])
    }
}
