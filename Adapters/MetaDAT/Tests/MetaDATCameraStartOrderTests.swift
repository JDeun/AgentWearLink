import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATCameraStartOrderTests: XCTestCase {
    func testSynchronousFirstFrameCannotPrecedeObservation() {
        var observerArmed = false
        var immediateFrameObserved = false

        let marker = MetaDATCameraStartOrder.armBeforeStart(
            observe: {
                observerArmed = true
                return "listener-installed"
            },
            start: {
                // Mimic an SDK that emits its first frame from start().
                immediateFrameObserved = observerArmed
            }
        )

        XCTAssertEqual(marker, "listener-installed")
        XCTAssertTrue(immediateFrameObserved)
    }
}
