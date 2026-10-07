import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkMetaDATIntegration

final class MetaDATDeviceEventSourceTests: XCTestCase {
    func testEventPublishedImmediatelyAfterStreamCreationIsRetained() async {
        let source = MetaDATDeviceEventSource(bufferLimit: 4)
        let stream = source.stream()
        let id = InteractionID()

        source.yield(.sessionStarted(id))

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .sessionStarted(id))
    }

    func testReplacementSubscriptionRetiresOnlyPreviousGeneration() async {
        let source = MetaDATDeviceEventSource(bufferLimit: 4)
        let first = source.stream()
        var firstIterator = first.makeAsyncIterator()

        let replacement = source.stream()
        var replacementIterator = replacement.makeAsyncIterator()

        let firstTerminal = await firstIterator.next()
        XCTAssertNil(firstTerminal)

        let id = InteractionID()
        source.yield(.sessionStarted(id))
        let replacementEvent = await replacementIterator.next()
        XCTAssertEqual(replacementEvent, .sessionStarted(id))
    }

    func testOverflowTerminatesGenerationWithTypedFailure() async {
        let source = MetaDATDeviceEventSource(bufferLimit: 1)
        let stream = source.stream()
        let firstID = InteractionID()
        let secondID = InteractionID()

        source.yield(.sessionStarted(firstID))
        source.yield(.sessionStarted(secondID))

        var iterator = stream.makeAsyncIterator()
        let terminal = await iterator.next()

        guard case let .failed(id, .overloaded(message)) = terminal else {
            return XCTFail("Expected typed overload terminal event, got \(String(describing: terminal))")
        }
        XCTAssertEqual(id, secondID)
        XCTAssertTrue(message.contains("buffer capacity exceeded"))
        let end = await iterator.next()
        XCTAssertNil(end)
    }
}
