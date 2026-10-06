import Foundation
import XCTest
@testable import AgentWearLinkCore

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class HTTPAgentTransportTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

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

    func testMapsAuthenticationFailure() async throws {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }

        let transport = HTTPAgentTransport(
            configuration: .init(endpoint: URL(string: "https://example.invalid")!),
            session: makeSession()
        )
        let request = AgentRequest(interactionID: InteractionID(), text: "hello")

        do {
            for try await _ in await transport.send(request) {}
            XCTFail("Expected authentication failure")
        } catch let error as AWLError {
            XCTAssertEqual(error, .authentication)
        }
    }

    func testRejectsOversizedBufferedResponse() async throws {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data(repeating: 65, count: 16))
        }

        let transport = HTTPAgentTransport(
            configuration: .init(
                endpoint: URL(string: "https://example.invalid")!,
                maximumResponseBytes: 8
            ),
            session: makeSession()
        )
        let request = AgentRequest(interactionID: InteractionID(), text: "hello")

        do {
            for try await _ in await transport.send(request) {}
            XCTFail("Expected byte limit failure")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .transport("response exceeds configured byte limit")
            )
        }
    }

    func testCancellingUnknownInteractionDoesNotCreateState() async {
        let transport = HTTPAgentTransport(
            configuration: .init(
                endpoint: URL(string: "https://example.invalid")!
            ),
            session: makeSession()
        )

        await transport.cancel(interactionID: InteractionID())

        let count = await transport.operationCount()
        XCTAssertEqual(count, 0)
    }

    func testDuplicateInteractionIDIsRejectedWhileReserved() async throws {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data("ok".utf8))
        }

        let transport = HTTPAgentTransport(
            configuration: .init(
                endpoint: URL(string: "https://example.invalid")!
            ),
            session: makeSession()
        )
        let id = InteractionID()
        let request = AgentRequest(interactionID: id, text: "hello")

        _ = await transport.send(request)

        do {
            for try await _ in await transport.send(request) {}
            XCTFail("Expected duplicate interaction failure")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .transport("duplicate interaction ID")
            )
        }

        await transport.cancel(interactionID: id)
    }
}
