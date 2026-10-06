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
}
