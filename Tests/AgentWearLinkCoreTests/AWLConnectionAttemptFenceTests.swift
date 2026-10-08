import XCTest
@testable import AgentWearLinkCore

final class AWLConnectionAttemptFenceTests: XCTestCase {
    func testSecondStartCannotEnterWhileFirstOwnsSetup() throws {
        var fence = AWLConnectionAttemptFence()
        let first = try XCTUnwrap(fence.begin())
        XCTAssertTrue(fence.isStarting)
        XCTAssertNil(fence.begin())

        fence.finish(first)
        XCTAssertFalse(fence.isStarting)
        let second = fence.begin()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testRuntimeCallbackOwnershipSurvivesStartupFinishButNotDisconnect() throws {
        var fence = AWLConnectionAttemptFence()
        let attempt = try XCTUnwrap(fence.begin())
        XCTAssertTrue(fence.ownsRuntime(attempt))

        fence.finish(attempt)
        XCTAssertFalse(fence.isCurrent(attempt))
        XCTAssertTrue(fence.ownsRuntime(attempt))

        fence.invalidate()
        XCTAssertFalse(fence.ownsRuntime(attempt))
        let next = try XCTUnwrap(fence.begin())
        XCTAssertTrue(fence.ownsRuntime(next))
        XCTAssertFalse(fence.ownsRuntime(attempt))
    }

    func testDisconnectInvalidatesLateCompletionUntilCleanupFinishes() throws {
        var fence = AWLConnectionAttemptFence()
        let old = try XCTUnwrap(fence.begin())
        fence.invalidate()

        XCTAssertFalse(fence.isCurrent(old))
        XCTAssertNil(fence.begin(), "Do not overlap teardown with a new startup")
        fence.finish(old)

        let retry = try XCTUnwrap(fence.begin())
        XCTAssertTrue(fence.isCurrent(retry))
        fence.finish(old)
        XCTAssertTrue(fence.isStarting, "Stale completion must not release new owner")
        fence.finish(retry)
        XCTAssertFalse(fence.isStarting)
    }
}
