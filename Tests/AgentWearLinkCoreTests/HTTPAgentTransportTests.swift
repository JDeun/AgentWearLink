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

private final class StreamingURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let metricsLock = NSLock()
    private nonisolated(unsafe) static var chunksSentStorage = 0
    private nonisolated(unsafe) static var onStopStorage: (() -> Void)?
    static let totalChunks = 64

    private let stateLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func reset(onStop: (() -> Void)? = nil) {
        metricsLock.lock()
        chunksSentStorage = 0
        onStopStorage = onStop
        metricsLock.unlock()
    }

    static func chunksSent() -> Int {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return chunksSentStorage
    }

    private static func recordChunk() {
        metricsLock.lock()
        chunksSentStorage += 1
        metricsLock.unlock()
    }

    private static func stopHandler() -> (() -> Void)? {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return onStopStorage
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Transfer-Encoding": "chunked"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        sendChunk(at: 0)
    }

    private func sendChunk(at index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }

            self.stateLock.lock()
            let isStopped = self.stopped
            self.stateLock.unlock()
            guard !isStopped else { return }

            guard index < Self.totalChunks else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }

            Self.recordChunk()
            self.client?.urlProtocol(
                self,
                didLoad: Data(repeating: 65, count: 4)
            )

            // The third 4-byte chunk is the first one that crosses the
            // transport's 8-byte test ceiling. Give URLSession cancellation a
            // deterministic handoff window before the producer emits more
            // bytes. Without this pause, a synthetic URLProtocol can outrun
            // Foundation's asynchronous task cancellation on loaded CI
            // runners and make the test measure scheduler latency rather than
            // the transport's incremental bound.
            let nextDelay: TimeInterval = index == 2 ? 0.5 : 0
            DispatchQueue.global().asyncAfter(
                deadline: .now() + nextDelay
            ) { [weak self] in
                self?.sendChunk(at: index + 1)
            }
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldNotify = !stopped
        stopped = true
        stateLock.unlock()

        if shouldNotify {
            Self.stopHandler()?()
        }
    }
}

final class HTTPAgentTransportTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeStreamingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocolStub.self]
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

    func testCancelsStreamingResponseBeforeFullBodyAccumulation() async throws {
        let stopped = expectation(description: "streaming response cancelled")
        StreamingURLProtocolStub.reset {
            stopped.fulfill()
        }
        defer {
            StreamingURLProtocolStub.reset()
        }

        let transport = HTTPAgentTransport(
            configuration: .init(
                endpoint: URL(string: "https://example.invalid")!,
                maximumResponseBytes: 8
            ),
            session: makeStreamingSession()
        )
        let request = AgentRequest(interactionID: InteractionID(), text: "hello")

        do {
            for try await _ in await transport.send(request) {}
            XCTFail("Expected incremental byte limit failure")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .transport("response exceeds configured byte limit")
            )
        }

        await fulfillment(of: [stopped], timeout: 1.0)
        XCTAssertLessThan(
            StreamingURLProtocolStub.chunksSent(),
            StreamingURLProtocolStub.totalChunks
        )
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
