import XCTest
@testable import AgentWearLinkCore

final class BoundedAsyncChannelTests: XCTestCase {
    func testDropsOldestWhenCapacityIsExceeded() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 2)

        await channel.send(1)
        await channel.send(2)
        await channel.send(3)

        let first = await channel.next()
        let second = await channel.next()

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 3)
    }

    func testFinishUnblocksWaitingConsumer() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1)

        let task = Task { await channel.next() }
        await Task.yield()
        await channel.finish()

        let value = await task.value
        XCTAssertNil(value)
    }
}
