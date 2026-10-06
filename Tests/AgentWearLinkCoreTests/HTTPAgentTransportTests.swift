import XCTest
@testable import AgentWearLinkCore

final class HTTPAgentTransportTests: XCTestCase {
    func testConfigurationCarriesResponseBound() {
        let endpoint = URL(string: "https://example.invalid/agent")!
        let configuration = HTTPAgentTransportConfiguration(
            endpoint: endpoint,
            timeout: 12,
            maximumResponseBytes: 4096
        )

        XCTAssertEqual(configuration.endpoint, endpoint)
        XCTAssertEqual(configuration.timeout, 12)
        XCTAssertEqual(configuration.maximumResponseBytes, 4096)
    }

    func testDefaultResponseBoundIsFinite() {
        let configuration = HTTPAgentTransportConfiguration(
            endpoint: URL(string: "https://example.invalid/agent")!
        )

        XCTAssertEqual(configuration.maximumResponseBytes, 1_048_576)
    }
}
