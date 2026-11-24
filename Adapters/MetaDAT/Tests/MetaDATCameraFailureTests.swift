import Foundation
import MWDATCamera
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATCameraFailureTests: XCTestCase {
    func testTypedDAT11PowerErrorsRemainDistinct() {
        XCTAssertEqual(MetaDATCameraFailure(.thermalHot), .thermalHot)
        XCTAssertEqual(MetaDATCameraFailure(.batteryLow), .batteryLow)
        XCTAssertEqual(MetaDATCameraFailure(.peakPowerLimit), .peakPowerLimit)
        XCTAssertEqual(MetaDATCameraFailure(.videoStreamingError), .streamFailed)
        XCTAssertEqual(MetaDATCameraFailure(.photoCaptureFailed), .streamFailed)
        XCTAssertEqual(MetaDATCameraFailure(.deviceNotConnected("private-device-id")).rawValue, "streamFailed")
    }

    func testFailureBeforeObserverIsReplayedAcrossCapturePhases() throws {
        let latch = MetaDATCameraFailureLatch()
        latch.record(.batteryLow)
        let first = expectation(description: "startup observer")
        let second = expectation(description: "photo observer")
        latch.observe { error in
            XCTAssertEqual(error, .batteryLow)
            first.fulfill()
        }
        latch.observe { error in
            XCTAssertEqual(error, .batteryLow)
            second.fulfill()
        }
        latch.record(.streamFailed)
        wait(for: [first, second], timeout: 1)
        XCTAssertThrowsError(try latch.check()) { XCTAssertEqual($0 as? MetaDATCameraFailure, .batteryLow) }
    }

    func testErrorAfterReadinessIsNotLostAndIsCaptureLocal() throws {
        let old = MetaDATCameraFailureLatch()
        let fresh = MetaDATCameraFailureLatch()
        let failure = expectation(description: "mid-capture error")
        old.observe { error in
            XCTAssertEqual(error, .peakPowerLimit)
            failure.fulfill()
        }
        old.record(.peakPowerLimit)
        wait(for: [failure], timeout: 1)
        XCTAssertThrowsError(try old.check())
        XCTAssertNoThrow(try fresh.check())
    }
}
