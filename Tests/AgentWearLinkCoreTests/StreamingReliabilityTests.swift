import Foundation
import XCTest
@testable import AgentWearLinkCore

final class StreamingReliabilityTests: XCTestCase {
    func testCancelledChannelConsumerDoesNotStealNextValue() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 2)
        let cancelled = Task { await channel.next() }
        await Task.yield()
        cancelled.cancel()
        let cancelledValue = await cancelled.value\n        XCTAssertNil(cancelledValue)

        await channel.send(42)
        let value = await channel.next()
        XCTAssertEqual(value, 42)
    }

    func testSSEParserRejectsOversizedPartialLineAndRecovers() throws {
        var parser = SSEParser(maximumBufferedBytes: 16)
        XCTAssertThrowsError(try parser.append(Data(repeating: 120, count: 17)))
        let events = try parser.append(Data("data: ok\n\n".utf8))
        XCTAssertEqual(events, [ServerSentEvent(data: "ok")])
    }

    func testSSEParserBoundsUnterminatedMultilineEvent() throws {
        var parser = SSEParser(maximumBufferedBytes: 20)
        _ = try parser.append(Data("data: 1234\n".utf8))
        XCTAssertThrowsError(try parser.append(Data("data: 567890\n".utf8)))
    }
}
