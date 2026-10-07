import Foundation
import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkOpenClaw

private final class OpenClawURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class OpenClawAdapterTests: XCTestCase {
    override func tearDown() {
        OpenClawURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testCompatibilityRequestRejectsBearerCredentialsOnRemotePlainHTTP() {
        let configuration = OpenClawConfiguration(
            baseURL: URL(string: "http://gateway.example.test:18789")!,
            bearerToken: "secret",
            conversationID: "compat-test"
        )

        XCTAssertThrowsError(
            try OpenClawRequestFactory.makeRequest(
                configuration: configuration,
                request: AgentRequest(
                    interactionID: InteractionID(),
                    text: "hello"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AWLError,
                .transport(
                    "OpenClaw bearer credentials require HTTPS or an explicit loopback HTTP endpoint"
                )
            )
        }
    }

    func testCompatibilityRequestAllowsHTTPSAndExplicitLoopbackHTTP() throws {
        let endpoints = [
            "https://gateway.example.test:18789",
            "http://localhost:18789",
            "http://127.0.0.1:18789",
            "http://[::1]:18789"
        ]

        for endpoint in endpoints {
            let configuration = OpenClawConfiguration(
                baseURL: URL(string: endpoint)!,
                bearerToken: "secret",
                conversationID: "compat-test"
            )
            let request = try OpenClawRequestFactory.makeRequest(
                configuration: configuration,
                request: AgentRequest(
                    interactionID: InteractionID(),
                    text: "hello"
                )
            )

            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer secret",
                endpoint
            )
        }
    }

    func testRequestUsesStableConversationAndOperatorToken() throws {
        let config = OpenClawConfiguration(
            baseURL: URL(string: "https://gateway.example.test:18789")!,
            bearerToken: "secret",
            conversationID: "wearable-main",
            sessionKey: "awl:test",
            messageChannel: "agentwearlink"
        )
        let id = InteractionID()
        let request = try OpenClawRequestFactory.makeRequest(
            configuration: config,
            request: AgentRequest(interactionID: id, text: "hello")
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://gateway.example.test:18789/v1/chat/completions"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-openclaw-session-key"),
            "awl:test"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-openclaw-message-channel"),
            "agentwearlink"
        )

        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["model"] as? String, "openclaw/default")
        XCTAssertEqual(json["user"] as? String, "agentwearlink:wearable-main")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testSSEParserDecodesTextDelta() throws {
        let line = #"data: {"choices":[{"delta":{"content":"안녕하세요"},"finish_reason":null}]}"#

        XCTAssertEqual(
            try OpenClawSSEParser.parse(
                line: line,
                maximumEventBytes: 4096
            ),
            .delta("안녕하세요")
        )
    }

    func testSSEParserRecognizesDone() throws {
        XCTAssertEqual(
            try OpenClawSSEParser.parse(
                line: "data: [DONE]",
                maximumEventBytes: 4096
            ),
            .done
        )
    }

    func testSSEParserRejectsOversizedEvent() {
        let line = "data: " + String(repeating: "x", count: 100)

        XCTAssertThrowsError(
            try OpenClawSSEParser.parse(
                line: line,
                maximumEventBytes: 16
            )
        )
    }

    func testCompatibilityStreamStopsAtDoneAndIgnoresLateDelta() async throws {
        let adapter = makeCompatibilityAdapter(
            payload: [
                deltaLine("first"),
                "data: [DONE]",
                deltaLine("late")
            ].joined(separator: "\n") + "\n"
        )
        let id = InteractionID()
        var responses: [AgentResponse] = []

        for try await response in await adapter.responses(
            for: AgentRequest(interactionID: id, text: "hello")
        ) {
            responses.append(response)
        }

        XCTAssertEqual(
            responses,
            [
                .textDelta(id, "first"),
                .completed(id)
            ]
        )
        let count = await adapter.taskCount()
        XCTAssertEqual(count, 0)
    }

    func testCompatibilityStreamRejectsEOFWithoutDone() async {
        let adapter = makeCompatibilityAdapter(
            payload: deltaLine("partial") + "\n"
        )
        let id = InteractionID()
        var responses: [AgentResponse] = []

        do {
            for try await response in await adapter.responses(
                for: AgentRequest(interactionID: id, text: "hello")
            ) {
                responses.append(response)
            }
            XCTFail("expected premature EOF failure")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .transport("OpenClaw SSE stream ended before [DONE]")
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(responses, [.textDelta(id, "partial")])
        let count = await adapter.taskCount()
        XCTAssertEqual(count, 0)
    }

    func testCompatibilityStreamDuplicateDoneIsHarmless() async throws {
        let adapter = makeCompatibilityAdapter(
            payload: "data: [DONE]\ndata: [DONE]\n"
        )
        let id = InteractionID()
        var responses: [AgentResponse] = []

        for try await response in await adapter.responses(
            for: AgentRequest(interactionID: id, text: "hello")
        ) {
            responses.append(response)
        }

        XCTAssertEqual(responses, [.completed(id)])
        let count = await adapter.taskCount()
        XCTAssertEqual(count, 0)
    }

    func testCompatibilityImmediateHTTPFailureCleansTaskRegistry() async {
        let adapter = makeCompatibilityAdapter(
            payload: "",
            statusCode: 500
        )
        let id = InteractionID()

        do {
            for try await _ in await adapter.responses(
                for: AgentRequest(interactionID: id, text: "hello")
            ) {}
            XCTFail("expected HTTP failure")
        } catch let error as AWLError {
            XCTAssertEqual(error, .transport("HTTP 500"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let count = await adapter.taskCount()
        XCTAssertEqual(count, 0)
    }

    private func makeCompatibilityAdapter(
        payload: String,
        statusCode: Int = 200
    ) -> OpenClawChatCompletionsAdapter {
        OpenClawURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/event-stream"
                ]
            )!
            return (response, Data(payload.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenClawURLProtocolStub.self]
        let session = URLSession(configuration: configuration)

        return OpenClawChatCompletionsAdapter(
            configuration: OpenClawConfiguration(
                baseURL: URL(string: "https://gateway.example.test")!,
                bearerToken: "secret",
                conversationID: "compat-test"
            ),
            session: session
        )
    }

    private func deltaLine(_ text: String) -> String {
        let encoded = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"data: {"choices":[{"delta":{"content":""# +
            encoded +
            #""},"finish_reason":null}]}"#
    }
}
