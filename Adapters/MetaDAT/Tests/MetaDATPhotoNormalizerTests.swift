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

    func testStreamJPEGRejectsPNGAndUnknownBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertThrowsError(
            try MetaDATPhotoNormalizer.validateStreamJPEG(
                png, maximumBytes: 20
            )
        ) { error in
            XCTAssertEqual(error as? MetaDATPhotoNormalizationError, .unexpectedJPEGEncoding)
        }
    }

    func testStreamJPEGChecksSignatureAndMaximumBeforeHandoff() throws {
        let jpegPrefix = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertNoThrow(
            try MetaDATPhotoNormalizer.validateStreamJPEG(
                jpegPrefix, maximumBytes: 4
            )
        )
        XCTAssertThrowsError(
            try MetaDATPhotoNormalizer.validateStreamJPEG(
                jpegPrefix, maximumBytes: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? MetaDATPhotoNormalizationError,
                .payloadTooLarge(actual: 4, maximum: 3)
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
