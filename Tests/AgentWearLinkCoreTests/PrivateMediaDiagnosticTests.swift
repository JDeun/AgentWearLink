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

    func testAgentRequestDiagnosticsRedactUserText() {
        let sentinel = "AWL_PRIVATE_TEXT_SENTINEL_AGENT_REQUEST"
        let request = AgentRequest(interactionID: InteractionID(), text: sentinel)

        assertRedacted(sentinel, from: request)
    }

    func testAgentResponseDiagnosticsRedactTextDeltaAndFailureDetails() {
        let textSentinel = "AWL_PRIVATE_TEXT_SENTINEL_AGENT_RESPONSE"
        let errorSentinel = "AWL_PRIVATE_ERROR_SENTINEL_AGENT_RESPONSE"
        let id = InteractionID()

        assertRedacted(textSentinel, from: AgentResponse.textDelta(id, textSentinel))
        assertRedacted(errorSentinel, from: AgentResponse.failed(id, .agent(errorSentinel)))
    }

    func testInteractionEventDiagnosticsRedactTextInvocationAndFailureDetails() {
        let textSentinel = "AWL_PRIVATE_TEXT_SENTINEL_EVENT"
        let invocationSentinel = "AWL_PRIVATE_INVOCATION_SENTINEL_EVENT"
        let errorSentinel = "AWL_PRIVATE_ERROR_SENTINEL_EVENT"
        let id = InteractionID()

        assertRedacted(textSentinel, from: InteractionEvent.text(id, textSentinel))
        assertRedacted(invocationSentinel, from: InteractionEvent.invocation(id, invocationSentinel))
        assertRedacted(errorSentinel, from: InteractionEvent.failed(id, .device(errorSentinel)))
    }

    func testVisionRequestDiagnosticsRedactPromptText() throws {
        let promptSentinel = "AWL_PRIVATE_PROMPT_SENTINEL_VISION"
        let image = try ImageAttachment(data: Data([1, 2, 3]), format: .jpeg)
        let request = VisionRequest(
            interactionID: InteractionID(),
            prompt: promptSentinel,
            image: image
        )

        assertRedacted(promptSentinel, from: request)
        XCTAssertTrue(String(describing: request).contains("promptBytes: \(promptSentinel.utf8.count)"))
        XCTAssertTrue(String(describing: request).contains("imageBytes: 3"))
    }

    private func assertRedacted<T>(_ sentinel: String, from value: T) {
        XCTAssertFalse(String(describing: value).contains(sentinel))
        XCTAssertFalse(String(reflecting: value).contains(sentinel))
    }
}
