import XCTest
@testable import AgentWearLinkCore

final class AgentResponseBufferingTests: XCTestCase {
    func testMockAgentFailsFastWithoutLeakingSuccessAfterBufferOverflow() async throws {
        let adapter = MockAgentAdapter(responseBufferLimit: 2) { request in
            [
                .textDelta(request.interactionID, "one"),
                .textDelta(request.interactionID, "two"),
                .textDelta(request.interactionID, "three"),
                .completed(request.interactionID)
            ]
        }
        let id = InteractionID()
        let stream = await adapter.responses(
            for: AgentRequest(interactionID: id, text: "hello")
        )

        try await waitUntilTestCondition("mock agent response overflow") {
            await adapter.responseBufferOverflowCount == 1
        }

        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()

        XCTAssertEqual(first, .textDelta(id, "one"))
        XCTAssertEqual(second, .textDelta(id, "two"))

        do {
            _ = try await iterator.next()
            XCTFail("Expected bounded response-stream overflow")
        } catch let error as AWLError {
            XCTAssertEqual(
                error,
                .overloaded("agent response stream buffer capacity exceeded")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
