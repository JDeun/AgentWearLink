import XCTest
import AgentWearLinkCore
@testable import AgentWearLinkAppleOutput

private actor SpeechSpy: SpeechSynthesizing {
    private var spoken: [String] = []
    private var stops = 0
    func speak(_ text: String) async { spoken.append(text) }
    func stop() async { stops += 1 }
    func values() -> ([String], Int) { (spoken, stops) }
}

final class AppleSpeechOutputTests: XCTestCase {
    func testDeltasAreCoalescedUntilCompletion() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.textDelta(id, "hello "))
        await output.consume(.textDelta(id, "world"))
        await output.consume(.completed(id))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["hello world"])
    }

    func testNewInteractionStopsPreviousSpeechAndDropsPendingText() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let first = InteractionID()
        let second = InteractionID()

        await output.consume(.textDelta(first, "stale"))
        await output.consume(.textDelta(second, "fresh"))
        await output.consume(.completed(second))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["fresh"])
        XCTAssertEqual(values.1, 2)
    }

    func testInterruptDropsPendingText() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.textDelta(id, "do not speak"))
        await output.interrupt(interactionID: id)
        await output.consume(.completed(id))

        let values = await spy.values()
        XCTAssertTrue(values.0.isEmpty)
    }
}
