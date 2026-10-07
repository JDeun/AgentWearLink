import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSessionGenerationFenceTests: XCTestCase {
    func testRetiredGenerationCannotOwnLaterRetry() {
        var fence = MetaDATSessionGenerationFence()

        let first = fence.begin()
        XCTAssertTrue(fence.owns(first))
        XCTAssertTrue(fence.retire(ifOwned: first))
        XCTAssertFalse(fence.owns(first))

        let retry = fence.begin()
        XCTAssertTrue(fence.owns(retry))
        XCTAssertFalse(fence.retire(ifOwned: first))
        XCTAssertTrue(fence.owns(retry))
    }

    func testUnconditionalRetirementInvalidatesCurrentGeneration() {
        var fence = MetaDATSessionGenerationFence()

        let generation = fence.begin()
        XCTAssertTrue(fence.owns(generation))

        XCTAssertTrue(fence.retire())
        XCTAssertFalse(fence.owns(generation))
    }

    func testRepeatedStaleRetirementCannotAdvanceCurrentGeneration() {
        var fence = MetaDATSessionGenerationFence()

        let first = fence.begin()
        XCTAssertTrue(fence.retire(ifOwned: first))
        let second = fence.begin()
        let currentBeforeStaleCallback = fence.current

        XCTAssertFalse(fence.retire(ifOwned: first))
        XCTAssertEqual(fence.current, currentBeforeStaleCallback)
        XCTAssertTrue(fence.owns(second))
    }
}
