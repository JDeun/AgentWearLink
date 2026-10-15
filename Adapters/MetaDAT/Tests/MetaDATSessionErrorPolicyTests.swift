import MWDATCore
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATSessionErrorPolicyTests: XCTestCase {
    private let all: [(DeviceSessionError, MetaDATSessionErrorKind, MetaDATSessionErrorResponse)] = [
        (.noEligibleDevice, .noEligibleDevice, .reconnect),
        (.sessionAlreadyStopped, .sessionAlreadyStopped, .reconnect),
        (.sessionAlreadyExists, .sessionAlreadyExists, .reconnect),
        (.sessionIdle, .sessionIdle, .reconnect),
        (.capabilityAlreadyActive, .capabilityAlreadyActive, .reconnect),
        (.capabilityNotFound, .capabilityNotFound, .reconnect),
        (.unexpectedError(description: "x"), .unexpectedError, .reconnect),
        (.thermalCritical, .thermalCritical, .coolDown),
        (.thermalEmergency, .thermalEmergency, .coolDown),
        (.peakPowerShutdown, .peakPowerShutdown, .coolDown),
        (.batteryCritical, .batteryCritical, .waitForCharge),
        (.datAppOnTheGlassesUpdateRequired, .datAppOnTheGlassesUpdateRequired, .updateGlassesApp),
        (.dwaUnavailable, .dwaUnavailable, .updateGlassesApp),
        (.insufficientSDKVersion, .insufficientSDKVersion, .updateCompanionApp),
        (.dwaOutOfStuRange, .dwaOutOfStuRange, .continueSession),
    ]

    func testEveryPublicCaseIsClassified() {
        XCTAssertEqual(Set(all.map(\.1)), Set(MetaDATSessionErrorKind.allCases))
        for (error, kind, response) in all {
            XCTAssertEqual(MetaDATSessionErrorKind(error), kind)
            XCTAssertEqual(MetaDATSessionErrorKind(classifying: error), kind)
            XCTAssertEqual(kind.response, response, "\(kind)")
        }
    }

    // Meta: only dwaOutOfStuRange lets the session proceed.
    func testOnlyTheOutOfRangeWarningKeepsTheSession() {
        let continuing = MetaDATSessionErrorKind.allCases.filter { !$0.response.endsSession }
        XCTAssertEqual(continuing, [.dwaOutOfStuRange])
    }

    func testVendorPayloadNeverReachesTheLoggedName() {
        let kind = MetaDATSessionErrorKind(.unexpectedError(description: "SECRET_CLIENT_TOKEN=meta-xyz DEVICE_SERIAL=1"))
        XCTAssertEqual(kind.rawValue, "unexpectedError")
    }

    func testOtherErrorsAreNotSessionErrors() {
        XCTAssertNil(MetaDATSessionErrorKind(classifying: CancellationError()))
        XCTAssertNil(MetaDATSessionErrorKind(classifying: URLError(.timedOut)))
    }
}
