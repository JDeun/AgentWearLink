import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVoiceListenerStartFenceTests: XCTestCase {
    func testConcurrentStartDoesNotAllocateSecondListener() throws {
        var fence = MetaDATVoiceListenerStartFence()
        let first = try XCTUnwrap(fence.begin())
        XCTAssertNil(fence.begin())
        XCTAssertTrue(fence.owns(first))
        fence.finish(first)
        XCTAssertFalse(fence.isStarting)
    }

    func testStopDuringSuspendedAllocationRejectsLateChannel() throws {
        var fence = MetaDATVoiceListenerStartFence()
        let old = try XCTUnwrap(fence.begin())
        fence.invalidate()
        XCTAssertFalse(fence.owns(old))
        let replacement = try XCTUnwrap(fence.begin())
        XCTAssertTrue(fence.owns(replacement))
        fence.finish(old)
        XCTAssertTrue(fence.isStarting)
        fence.finish(replacement)
        XCTAssertFalse(fence.isStarting)
    }
}
