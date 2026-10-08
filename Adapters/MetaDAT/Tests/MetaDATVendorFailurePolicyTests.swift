import Foundation
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATVendorFailurePolicyTests: XCTestCase {
    struct SensitiveVendorError: LocalizedError {
        let errorDescription: String? =
            "SECRET_CLIENT_TOKEN=meta-xyz DEVICE_SERIAL=private"
    }

    func testUntrustedSessionErrorDescriptionIsNotForwarded() {
        let message = MetaDATVendorFailurePolicy.message(
            for: SensitiveVendorError(), surface: .session
        )
        XCTAssertEqual(message, "Meta DAT device session error (details redacted)")
        XCTAssertFalse(message.contains("SECRET_CLIENT_TOKEN"))
        XCTAssertFalse(message.contains("DEVICE_SERIAL"))
    }

    func testUntrustedSpeechErrorDescriptionIsNotForwarded() {
        let message = MetaDATVendorFailurePolicy.message(
            for: SensitiveVendorError(), surface: .speech
        )
        XCTAssertEqual(message, "Meta DAT Speech error (details redacted)")
        XCTAssertFalse(message.contains("SECRET_CLIENT_TOKEN"))
        XCTAssertFalse(message.contains("DEVICE_SERIAL"))
    }
}
