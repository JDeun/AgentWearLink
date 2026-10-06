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

    func testRingBufferPreservesNewestValuesAcrossHeavyWraparound() async {
        let capacity = 32
        let channel = BoundedAsyncChannel<Int>(capacity: capacity)

        for value in 0..<10_000 {
            await channel.send(value)
        }

        var received: [Int] = []
        for _ in 0..<capacity {
            if let value = await channel.next() {
                received.append(value)
            }
        }

        XCTAssertEqual(
            received,
            Array((10_000 - capacity)..<10_000)
        )
    }

    func testFinishUnblocksWaitingConsumer() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 1)

        let task = Task { await channel.next() }
        await Task.yield()
        await channel.finish()

        let value = await task.value
        XCTAssertNil(value)
    }

    func testFinishDropsBufferedValuesAndRejectsFutureSends() async {
        let channel = BoundedAsyncChannel<Int>(capacity: 3)

        await channel.send(1)
        await channel.send(2)
        await channel.finish()
        await channel.send(3)

        let firstAfterFinish = await channel.next()
        let secondAfterFinish = await channel.next()
        XCTAssertNil(firstAfterFinish)
        XCTAssertNil(secondAfterFinish)
    }
}
