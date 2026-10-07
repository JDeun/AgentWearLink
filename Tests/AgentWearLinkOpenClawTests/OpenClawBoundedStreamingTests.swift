import Foundation
import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkOpenClaw

private final class OpenClawIncrementalSSEURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OpenClawBoundedStreamingTests: XCTestCase {
    override func tearDown() {
        OpenClawIncrementalSSEURLProtocolStub.payload = Data()
        super.tearDown()
    }

    func testOversizedUnterminatedSSELineFailsWhileReadingBytes() async throws {
        OpenClawIncrementalSSEURLProtocolStub.payload = Data(
            ("data: " + String(repeating: "x", count: 256)).utf8
        )
        let adapter = makeAdapter(maximumEventBytes: 16)
        let id = InteractionID()

        do {
            for try await _ in await adapter.responses(
                for: AgentRequest(interactionID: id, text: "hello")
            ) {}
            XCTFail("Expected incremental SSE byte limit failure")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .transport("SSE event exceeds configured byte limit")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let taskCount = await adapter.taskCount()
        XCTAssertEqual(taskCount, 0)
    }

    func testIncrementalLineParserPreservesCRLFAndDoneSemantics() async throws {
        OpenClawIncrementalSSEURLProtocolStub.payload = Data(
            (
                #"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"#
                + "\r\n"
                + "data: [DONE]\r\n"
            ).utf8
        )
        let adapter = makeAdapter(maximumEventBytes: 4_096)
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
                .textDelta(id, "hello"),
                .completed(id),
            ]
        )
    }

    private func makeAdapter(
        maximumEventBytes: Int
    ) -> OpenClawChatCompletionsAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenClawIncrementalSSEURLProtocolStub.self]
        let session = URLSession(configuration: configuration)

        return OpenClawChatCompletionsAdapter(
            configuration: OpenClawConfiguration(
                baseURL: URL(string: "https://gateway.example.test")!,
                bearerToken: "secret",
                conversationID: "bounded-stream",
                maximumEventBytes: maximumEventBytes
            ),
            session: session
        )
    }
}
