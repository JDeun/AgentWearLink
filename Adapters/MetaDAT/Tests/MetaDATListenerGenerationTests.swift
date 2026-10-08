import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATListenerGenerationTests: XCTestCase {
    func testStopThenImmediateRestartRejectsRetiredCallback() {
        let gate = MetaDATListenerGeneration()
        var deliveries: [String] = []

        let retired = gate.begin()
        let retiredCallback = {
            if gate.isCurrent(retired) {
                deliveries.append("retired")
            }
        }

        gate.invalidate()

        let current = gate.begin()
        let currentCallback = {
            if gate.isCurrent(current) {
                deliveries.append("current")
            }
        }

        retiredCallback()
        currentCallback()

        XCTAssertEqual(deliveries, ["current"])
    }

    func testLateStreamTerminationCannotRetireNewCapture() {
        let gate = MetaDATListenerGeneration()
        let prior = gate.begin()
        XCTAssertTrue(gate.invalidate(ifCurrent: prior))

        // A later capture starts before the previous AsyncStream's
        // onTermination executes. That old callback must be inert.
        let replacement = gate.begin()
        XCTAssertFalse(gate.invalidate(ifCurrent: prior))
        XCTAssertTrue(gate.isCurrent(replacement))
        XCTAssertTrue(gate.invalidate(ifCurrent: replacement))
        XCTAssertFalse(gate.isCurrent(replacement))
        XCTAssertFalse(gate.invalidate(ifCurrent: replacement))
    }

    func testNewListenerGenerationSupersedesOlderListenerImmediately() {
        let gate = MetaDATListenerGeneration()

        let first = gate.begin()
        XCTAssertTrue(gate.isCurrent(first))

        let second = gate.begin()

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }
}
