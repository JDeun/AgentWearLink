import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVoiceMediaActivationPolicyTests: XCTestCase {
    func testForegroundOptInAllowsOneMediaHandoffAfterVoiceAck() {
        XCTAssertTrue(MetaDATVoiceMediaActivationPolicy.mayActivate(
            optedIn: true,
            foreground: true,
            connecting: false,
            sessionActive: false,
            stopping: false
        ))
    }

    func testNeverStartsMediaWhileBackgroundedOrWithoutOptIn() {
        for optedIn in [false, true] {
            for foreground in [false, true] {
                if optedIn && foreground { continue }
                XCTAssertFalse(MetaDATVoiceMediaActivationPolicy.mayActivate(
                    optedIn: optedIn, foreground: foreground, connecting: false,
                    sessionActive: false, stopping: false
                ))
            }
        }
    }

    func testRefusesConcurrentOrAlreadyActiveOrStoppingMedia() {
        for (connecting, active, stopping) in [
            (true, false, false), (false, true, false),
            (false, false, true), (true, true, true)
        ] {
            XCTAssertFalse(MetaDATVoiceMediaActivationPolicy.mayActivate(
                optedIn: true, foreground: true, connecting: connecting,
                sessionActive: active, stopping: stopping
            ))
        }
    }
}
