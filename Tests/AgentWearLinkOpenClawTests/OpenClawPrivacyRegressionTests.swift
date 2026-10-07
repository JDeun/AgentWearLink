import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawPrivacyRegressionTests: XCTestCase {
    func testConfigurationDescriptionDoesNotExposeBearerToken() {
        let secret = "AWL_SECRET_SENTINEL_7F3A"
        let configuration = OpenClawConfiguration(
            baseURL: URL(string: "https://gateway.example.test:18789")!,
            bearerToken: secret,
            conversationID: "privacy-test",
            sessionKey: "agent:main:main",
            messageChannel: "agentwearlink"
        )

        XCTAssertFalse(String(describing: configuration).contains(secret))
        XCTAssertFalse(String(reflecting: configuration).contains(secret))
    }

    func testConfigurationDescriptionRedactsConversationRoutingIdentifiers() {
        let conversationID = "AWL_CONVERSATION_SENTINEL_A1"
        let sessionKey = "AWL_SESSION_SENTINEL_B2"
        let messageChannel = "AWL_CHANNEL_SENTINEL_C3"
        let configuration = OpenClawConfiguration(
            baseURL: URL(string: "https://gateway.example.test:18789")!,
            bearerToken: "token",
            conversationID: conversationID,
            sessionKey: sessionKey,
            messageChannel: messageChannel
        )

        for rendered in [
            String(describing: configuration),
            String(reflecting: configuration)
        ] {
            XCTAssertFalse(rendered.contains(conversationID))
            XCTAssertFalse(rendered.contains(sessionKey))
            XCTAssertFalse(rendered.contains(messageChannel))
            XCTAssertTrue(rendered.contains("conversationID: <redacted>"))
            XCTAssertTrue(rendered.contains("sessionKey: <redacted>"))
            XCTAssertTrue(rendered.contains("messageChannel: <redacted>"))
        }
    }

    func testConfigurationDescriptionPreservesAbsentOptionalRoutingState() {
        let configuration = OpenClawConfiguration(
            baseURL: URL(string: "https://gateway.example.test:18789")!,
            bearerToken: "token",
            conversationID: "privacy-test"
        )

        let rendered = String(describing: configuration)
        XCTAssertTrue(rendered.contains("conversationID: <redacted>"))
        XCTAssertTrue(rendered.contains("sessionKey: nil"))
        XCTAssertTrue(rendered.contains("messageChannel: nil"))
    }

    func testEndpointDescriptionDoesNotExposeCredentialSentinel() throws {
        let secret = "AWL_SECRET_SENTINEL_9C2B"
        let configuration = OpenClawConfiguration(
            baseURL: URL(string: "https://gateway.example.test:18789")!,
            bearerToken: secret,
            conversationID: "privacy-test"
        )
        let request = try OpenClawRequestFactory.makeRequest(
            configuration: configuration,
            request: .init(interactionID: .init(), text: "harmless")
        )

        // Authorization is required on the wire, but generic request
        // descriptions used by diagnostics must not render its value.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
        XCTAssertFalse(String(describing: request).contains(secret))
    }
    func testDeviceIdentityAndConnectAuthDescriptionsRedactSecrets() throws {
        let identity = OpenClawDeviceIdentity.generate()
        let key = identity.privateKeyRaw.base64EncodedString()
        XCTAssertFalse(String(describing: identity).contains(key))
        XCTAssertFalse(String(reflecting: identity).contains(key))
        let secrets = ["TOKEN_SENTINEL", "PASSWORD_SENTINEL", "BOOTSTRAP_SENTINEL"]
        let auth = OpenClawConnectParams.Auth(token: secrets[0], password: secrets[1], bootstrapToken: secrets[2])
        for rendered in [String(describing: auth), String(reflecting: auth)] {
            for secret in secrets { XCTAssertFalse(rendered.contains(secret)) }
            XCTAssertTrue(rendered.contains("<redacted>"))
        }
    }

}
