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

    func testRejectsBearerCredentialsOnRemotePlainHTTPAtConnectBoundary() async {
        let transport = HTTPAgentTransport(configuration: .init(
            endpoint: URL(string: "http://example.invalid/agent")!,
            bearerToken: "secret"
        ))

        do {
            try await transport.connect()
            XCTFail("Expected insecure credential transport rejection")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .transport("bearer credentials require HTTPS or an explicit loopback HTTP endpoint")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAllowsBearerCredentialsOnHTTPSAndLoopbackHTTP() async throws {
        let endpoints = [
            "https://example.invalid/agent",
            "http://localhost:8080/agent",
            "http://127.0.0.1:8080/agent",
            "http://[::1]:8080/agent"
        ]

        for endpoint in endpoints {
            let transport = HTTPAgentTransport(configuration: .init(
                endpoint: URL(string: endpoint)!,
                bearerToken: "secret"
            ))
            try await transport.connect()
        }
    }

    func testAllowsCredentialFreeRemoteHTTPForExplicitDevelopmentUse() async throws {
        let transport = HTTPAgentTransport(configuration: .init(
            endpoint: URL(string: "http://example.invalid/agent")!
        ))

        try await transport.connect()
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

    func testConfigurationDescriptionsRedactBearerToken() {
        let secret = "AWL_HTTP_SECRET_SENTINEL"
        let configuration = HTTPAgentTransportConfiguration(
            endpoint: URL(string: "https://example.invalid/agent")!,
            bearerToken: secret,
            timeout: 12,
            maximumResponseBytes: 4096
        )

        let description = String(describing: configuration)
        let reflection = String(reflecting: configuration)

        XCTAssertFalse(description.contains(secret))
        XCTAssertFalse(reflection.contains(secret))
        XCTAssertTrue(description.contains("<redacted>"))
        XCTAssertTrue(reflection.contains("<redacted>"))
        XCTAssertTrue(description.contains("https://example.invalid/agent"))
        XCTAssertTrue(description.contains("4096"))
    }

    func testConfigurationDescriptionsDoNotInventCredentialWhenAbsent() {
        let configuration = HTTPAgentTransportConfiguration(
            endpoint: URL(string: "https://example.invalid/agent")!
        )

        XCTAssertTrue(String(describing: configuration).contains("bearerToken: nil"))
        XCTAssertTrue(String(reflecting: configuration).contains("bearerToken: nil"))
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

    func testResponseLoaderCancelsBeforeOversizedChunkCanBeAccumulated() {
        let lock = NSLock()
        var events: [String] = []
        var terminalError: AWLError?

        let request = URLRequest(
            url: URL(string: "https://example.invalid")!
        )
        let loader = BoundedHTTPResponseLoader(
            configuration: .ephemeral,
            request: request,
            maximumResponseBytes: 8
        ) { result in
            lock.lock()
            defer { lock.unlock() }

            events.append("completion")
            if case let .failure(error as AWLError) = result {
                terminalError = error
            }
        }

        loader.receiveBodyChunk(Data(repeating: 65, count: 4)) {
            XCTFail("first chunk must not cancel")
        }
        loader.receiveBodyChunk(Data(repeating: 66, count: 4)) {
            XCTFail("chunk at the exact limit must not cancel")
        }
        loader.receiveBodyChunk(Data(repeating: 67, count: 4)) {
            lock.lock()
            events.append("cancel")
            lock.unlock()
        }

        XCTAssertEqual(loader.bufferedResponseByteCount(), 8)
        XCTAssertEqual(
            terminalError,
            .transport("response exceeds configured byte limit")
        )
        XCTAssertEqual(events, ["cancel", "completion"])
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
