import Foundation
import XCTest
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATPhotoNormalizerTests: XCTestCase {
    func testPayloadExactlyAtConfiguredLimitIsAccepted() throws {
        let fixture = Data(repeating: 0xA5, count: 8)

        XCTAssertNoThrow(
            try MetaDATPhotoNormalizer.validatePayload(
                fixture,
                maximumBytes: 8
            )
        )
    }

    func testOversizedSyntheticFixtureIsRejectedBeforeHandoff() {
        let fixture = Data(repeating: 0xA5, count: 9)

        XCTAssertThrowsError(
            try MetaDATPhotoNormalizer.validatePayload(
                fixture,
                maximumBytes: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? MetaDATPhotoNormalizationError,
                .payloadTooLarge(actual: 9, maximum: 8)
            )
        }
    }

    func testDefaultMaximumIsFiniteAndPositive() {
        XCTAssertGreaterThan(
            MetaDATPhotoNormalizer.defaultMaximumBytes,
            0
        )
        XCTAssertEqual(
            MetaDATPhotoNormalizer.defaultMaximumBytes,
            16 * 1024 * 1024
        )
    }
}
