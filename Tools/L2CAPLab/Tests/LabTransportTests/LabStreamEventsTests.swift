import Foundation
import XCTest
@testable import LabTransport

final class LabStreamEventsTests: XCTestCase {
    func testCoalescesReadinessAndTerminalEventsAndYieldsAfterDrain() {
        var events = LabStreamEvents()
        let token = UUID()
        events.begin(generation: token)
        XCTAssertFalse(events.enqueue(generation: token, signals: []))
        XCTAssertTrue(events.enqueue(generation: token, signals: .ready))
        for _ in 0..<1000 { XCTAssertFalse(events.enqueue(generation: token, signals: .ready)) }
        XCTAssertFalse(events.enqueue(generation: token, signals: [.end, .error]))
        XCTAssertEqual(events.take(generation: token), [.ready, .end, .error])
        XCTAssertNil(events.take(generation: token))
        XCTAssertTrue(events.enqueue(generation: token, signals: .ready))
        XCTAssertEqual(events.take(generation: token), .ready)
    }

    func testRetiredGenerationCannotScheduleOrConsumeNewEvents() {
        var events = LabStreamEvents()
        let old = UUID(), fresh = UUID()
        events.begin(generation: old)
        XCTAssertTrue(events.enqueue(generation: old, signals: .ready))
        events.retire()
        XCTAssertNil(events.take(generation: old))
        events.begin(generation: fresh)
        XCTAssertTrue(events.enqueue(generation: fresh, signals: .error))
        XCTAssertFalse(events.enqueue(generation: old, signals: .end))
        XCTAssertNil(events.take(generation: old))
        XCTAssertEqual(events.take(generation: fresh), .error)
    }
}
