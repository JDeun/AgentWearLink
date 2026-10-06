import XCTest
@testable import AgentWearLinkCore

final class VisionContractTests: XCTestCase {
    func testImageAttachmentAcceptsPayloadAtLimit() throws {
        let data = Data(repeating: 0, count: 16)
        let image = try ImageAttachment(data: data, format: .jpeg, maximumBytes: 16)
        XCTAssertEqual(image.data.count, 16)
    }

    func testImageAttachmentRejectsPayloadOverLimit() {
        XCTAssertThrowsError(
            try ImageAttachment(data: Data(repeating: 0, count: 17), format: .jpeg, maximumBytes: 16)
        ) { error in
            XCTAssertEqual(error as? AWLError, .capabilityUnavailable("image payload exceeds configured limit"))
        }
    }

    func testImageAttachmentRejectsNonPositiveLimit() {
        XCTAssertThrowsError(
            try ImageAttachment(data: Data(), format: .png, maximumBytes: 0)
        )
    }
}
