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

    func testNewListenerGenerationSupersedesOlderListenerImmediately() {
        let gate = MetaDATListenerGeneration()

        let first = gate.begin()
        XCTAssertTrue(gate.isCurrent(first))

        let second = gate.begin()

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
    }
}
