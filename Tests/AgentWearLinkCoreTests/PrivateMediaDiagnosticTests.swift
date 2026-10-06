import XCTest
@testable import AgentWearLinkCore

final class PrivateMediaDiagnosticTests: XCTestCase {
    func testImageAttachmentDescriptionsNeverSerializePayloadBytes() throws {
        let sentinel = Data("AWL_PRIVATE_MEDIA_SENTINEL_4E91".utf8)
        let image = try ImageAttachment(data: sentinel, format: .jpeg)

        XCTAssertFalse(String(describing: image).contains("AWL_PRIVATE_MEDIA_SENTINEL_4E91"))
        XCTAssertFalse(String(reflecting: image).contains("AWL_PRIVATE_MEDIA_SENTINEL_4E91"))
    }

    func testVisionRequestDescriptionsNeverSerializePrivateMedia() throws {
        let sentinelText = "AWL_PRIVATE_MEDIA_SENTINEL_83C7"
        let image = try ImageAttachment(data: Data(sentinelText.utf8), format: .png)
        let request = VisionRequest(
            interactionID: InteractionID(),
            prompt: "describe",
            image: image
        )

        XCTAssertFalse(String(describing: request).contains(sentinelText))
        XCTAssertFalse(String(reflecting: request).contains(sentinelText))
    }
}
