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
    func testNormalizedRuntimeEventsDriveSpeechOutput() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.text(id, "hello "))
        await output.consume(.text(id, "world"))
        await output.consume(.turnCompleted(id))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["hello world"])
        XCTAssertEqual(values.1, 0)
    }

    func testNormalizedInterruptionStopsAndDiscardsPendingSpeech() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.text(id, "do not speak"))
        await output.consume(.interrupted(id))
        await output.consume(.turnCompleted(id))

        let values = await spy.values()
        XCTAssertTrue(values.0.isEmpty)
        XCTAssertEqual(values.1, 1)
    }

    func testGlobalDeviceFailureInterruptsActiveOutput() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.text(id, "pending"))
        await output.consume(.failed(nil, .device("session lost")))

        let values = await spy.values()
        XCTAssertTrue(values.0.isEmpty)
        XCTAssertEqual(values.1, 1)
    }

    func testGlobalAgentDiagnosticDoesNotInterruptUnrelatedOutput() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.text(id, "safe"))
        await output.consume(.failed(nil, .agent("remote cancellation uncertain")))
        await output.consume(.turnCompleted(id))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["safe"])
        XCTAssertEqual(values.1, 0)
    }

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
        XCTAssertEqual(values.1, 1)
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

    func testLateDeltaAndDuplicateCompletionAreIgnoredAfterCompletion() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.textDelta(id, "first"))
        await output.consume(.completed(id))
        await output.consume(.textDelta(id, "late"))
        await output.consume(.completed(id))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["first"])
        XCTAssertEqual(values.1, 0)
    }

    func testFailureAfterCompletionDoesNotStopCompletedSpeech() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.textDelta(id, "finished"))
        await output.consume(.completed(id))
        await output.consume(.failed(id, .agent("late failure")))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["finished"])
        XCTAssertEqual(values.1, 0)
    }

    func testFreshInteractionAfterCompletionReplacesPriorSpeech() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let first = InteractionID()
        let second = InteractionID()

        await output.consume(.textDelta(first, "first"))
        await output.consume(.completed(first))
        await output.consume(.textDelta(second, "second"))
        await output.consume(.completed(second))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["first", "second"])
        XCTAssertEqual(values.1, 1)
    }

    func testInterruptCanStillStopSpeechAfterCompletion() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(synthesizer: spy)
        let id = InteractionID()

        await output.consume(.textDelta(id, "spoken"))
        await output.consume(.completed(id))
        await output.interrupt(interactionID: id)

        let values = await spy.values()
        XCTAssertEqual(values.0, ["spoken"])
        XCTAssertEqual(values.1, 1)
    }

    func testTextAtConfiguredUTF8BoundaryIsSpoken() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(
            synthesizer: spy,
            maximumBufferedTextBytes: 6
        )
        let id = InteractionID()

        await output.consume(.textDelta(id, "가"))
        await output.consume(.textDelta(id, "나"))
        await output.consume(.completed(id))

        let values = await spy.values()
        XCTAssertEqual(values.0, ["가나"])
        XCTAssertEqual(values.1, 0)
    }

    func testSustainedDeltasBeyondBufferLimitAreDroppedAndCannotResurrect() async {
        let spy = SpeechSpy()
        let output = AppleSpeechOutput(
            synthesizer: spy,
            maximumBufferedTextBytes: 8
        )
        let id = InteractionID()

        for _ in 0..<8 {
            await output.consume(.textDelta(id, "a"))
        }
        await output.consume(.textDelta(id, "overflow"))
        await output.consume(.textDelta(id, "late"))
        await output.consume(.completed(id))

        let values = await spy.values()
        XCTAssertTrue(values.0.isEmpty)
        XCTAssertEqual(values.1, 1)
    }
}
