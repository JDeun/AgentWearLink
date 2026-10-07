import AgentWearLinkCore
import Foundation
import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawVisionAdapterTests: XCTestCase {
    func testVisionAttachmentMapsCoreImageToOfficialWireShape() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let image = try ImageAttachment(
            data: bytes,
            format: .jpeg,
            maximumBytes: 4
        )

        let attachment = OpenClawNativeAgentAdapter.makeImageAttachment(image)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.fileName, "capture.jpg")
        XCTAssertEqual(attachment.content, bytes)
        XCTAssertEqual(attachment.rawByteCount, 4)
        XCTAssertEqual(attachment.base64EncodedByteCount, 8)
    }

    func testAgentParamsEncodeAttachmentContentAsBase64() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let params = OpenClawAgentParams(
            message: "describe",
            sessionKey: "agent:main:main",
            idempotencyKey: "idempotency",
            attachments: [
                .init(
                    mimeType: "image/png",
                    fileName: "capture.png",
                    content: bytes
                )
            ]
        )

        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let attachments = try XCTUnwrap(json["attachments"] as? [[String: Any]])
        let first = try XCTUnwrap(attachments.first)

        XCTAssertEqual(first["mimeType"] as? String, "image/png")
        XCTAssertEqual(first["fileName"] as? String, "capture.png")
        XCTAssertEqual(first["content"] as? String, bytes.base64EncodedString())
    }

    func testAttachmentDescriptionDoesNotExposePrivateMedia() {
        let privateBytes = Data("PRIVATE_MEDIA_SENTINEL".utf8)
        let attachment = OpenClawAgentAttachment(
            mimeType: "image/jpeg",
            fileName: "capture.jpg",
            content: privateBytes
        )

        for rendered in [
            String(describing: attachment),
            String(reflecting: attachment)
        ] {
            XCTAssertFalse(rendered.contains("PRIVATE_MEDIA_SENTINEL"))
            XCTAssertFalse(rendered.contains(privateBytes.base64EncodedString()))
            XCTAssertTrue(rendered.contains("contentBytes:"))
        }
    }

    func testAttachmentSubmissionRequiresNegotiatedAttachmentPolicy() async throws {
        let state = try await readyState(
            maxPayload: 1_024,
            attachments: nil
        )
        let attachment = OpenClawAgentAttachment(
            mimeType: "image/jpeg",
            fileName: "capture.jpg",
            content: Data([1])
        )

        do {
            try await state.validateAgentPayload(
                messageUTF8Bytes: 1,
                attachments: [attachment]
            )
            XCTFail("Expected missing attachment policy rejection")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(error, .attachmentsUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAttachmentSubmissionEnforcesPerImageLimitBeforeEncoding() async throws {
        let state = try await readyState(
            maxPayload: 1_024,
            attachments: .init(maxBytes: 32, maxImageBytes: 3)
        )
        let attachment = OpenClawAgentAttachment(
            mimeType: "image/jpeg",
            fileName: "capture.jpg",
            content: Data(repeating: 7, count: 4)
        )

        do {
            try await state.validateAgentPayload(
                messageUTF8Bytes: 1,
                attachments: [attachment]
            )
            XCTFail("Expected per-image limit rejection")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(
                error,
                .imageAttachmentTooLarge(actual: 4, maximum: 3)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAttachmentSubmissionEnforcesAggregateRawBudget() async throws {
        let state = try await readyState(
            maxPayload: 1_024,
            attachments: .init(maxBytes: 5, maxImageBytes: 4)
        )
        let attachments = [
            OpenClawAgentAttachment(
                mimeType: "image/jpeg",
                fileName: "a.jpg",
                content: Data(repeating: 1, count: 3)
            ),
            OpenClawAgentAttachment(
                mimeType: "image/jpeg",
                fileName: "b.jpg",
                content: Data(repeating: 2, count: 3)
            )
        ]

        do {
            try await state.validateAgentPayload(
                messageUTF8Bytes: 1,
                attachments: attachments
            )
            XCTFail("Expected aggregate attachment budget rejection")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(
                error,
                .attachmentBudgetExceeded(actual: 6, maximum: 5)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAttachmentSubmissionAccountsForBase64ExpansionBeforeEncoding() async throws {
        let state = try await readyState(
            maxPayload: 10,
            attachments: .init(maxBytes: 8, maxImageBytes: 8)
        )
        let attachment = OpenClawAgentAttachment(
            mimeType: "image/jpeg",
            fileName: "capture.jpg",
            content: Data(repeating: 3, count: 6)
        )

        // Six raw bytes expand to eight base64 bytes. Three prompt bytes make
        // the request exceed the ten-byte negotiated payload even before JSON
        // envelope overhead is allocated.
        do {
            try await state.validateAgentPayload(
                messageUTF8Bytes: 3,
                attachments: [attachment]
            )
            XCTFail("Expected base64-expanded payload rejection")
        } catch let error as AWLOpenClawError {
            XCTAssertEqual(
                error,
                .payloadTooLarge(actual: 11, maximum: 10)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAttachmentSubmissionAllowsBoundedPayloadForExactEncodingCheck() async throws {
        let state = try await readyState(
            maxPayload: 64,
            attachments: .init(maxBytes: 8, maxImageBytes: 8)
        )
        let attachment = OpenClawAgentAttachment(
            mimeType: "image/png",
            fileName: "capture.png",
            content: Data(repeating: 4, count: 6)
        )

        try await state.validateAgentPayload(
            messageUTF8Bytes: 3,
            attachments: [attachment]
        )
    }

    private func readyState(
        maxPayload: Int,
        attachments: OpenClawHelloOK.Policy.Attachments?
    ) async throws -> OpenClawGatewayState {
        let state = OpenClawGatewayState()
        await state.beginConnect()
        try await state.acceptHello(
            OpenClawHelloOK(
                type: "hello-ok",
                protocolVersion: 4,
                server: .init(version: "test", connId: "vision"),
                features: .init(methods: ["agent"], events: ["agent"]),
                auth: .init(
                    role: "operator",
                    scopes: ["operator.read", "operator.write"],
                    deviceToken: nil
                ),
                policy: .init(
                    maxPayload: maxPayload,
                    maxBufferedBytes: 4_096,
                    tickIntervalMs: 15_000,
                    attachments: attachments
                )
            )
        )
        return state
    }
}
