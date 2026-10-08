import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawEmittedTextAccumulatorTests: XCTestCase {
    func testAcceptsExactUTF8BudgetAndPreservesTextForTerminalReconciliation() async throws {
        let accumulator = OpenClawEmittedTextAccumulator(maximumBytes: 6)
        try await accumulator.append("é") // two UTF-8 bytes
        try await accumulator.append("test")
        let text = await accumulator.snapshot()
        XCTAssertEqual(text, "étest")
    }

    func testRejectsOverflowWithoutRetainingRejectedPrivateDelta() async throws {
        let accumulator = OpenClawEmittedTextAccumulator(maximumBytes: 5)
        try await accumulator.append("hello")

        do {
            try await accumulator.append("PRIVATE_SECRET_DELTA")
            XCTFail("Expected typed bounded response failure")
        } catch let error as OpenClawNativeAdapterError {
            XCTAssertEqual(error, .streamedTextBudgetExceeded(maximumBytes: 5))
            XCTAssertFalse(String(reflecting: error).contains("PRIVATE_SECRET_DELTA"))
        }

        let retained = await accumulator.snapshot()
        XCTAssertEqual(retained, "hello")
    }

    func testRejectsMultibyteOverflowBeforeEmission() async throws {
        let accumulator = OpenClawEmittedTextAccumulator(maximumBytes: 7)
        try await accumulator.append("ok")
        do {
            try await accumulator.append("🇰🇷") // 8 UTF-8 bytes
            XCTFail("Should check UTF-8 bytes, not grapheme count")
        } catch let error as OpenClawNativeAdapterError {
            XCTAssertEqual(error, .streamedTextBudgetExceeded(maximumBytes: 7))
        }
        let retained = await accumulator.snapshot()
        XCTAssertEqual(retained, "ok")
    }
}
