import Foundation
import XCTest
@testable import LabTransport

private final class Pipe {
    var bytes: [UInt8] = []
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
}
private final class DuplexPort: LabPort {
    let inbound: Pipe
    let outbound: Pipe
    let readLimit: Int
    let writeLimit: Int
    private(set) var operations = 0
    private(set) var blockedWrites = 0
    init(inbound: Pipe, outbound: Pipe, readLimit: Int, writeLimit: Int) {
        self.inbound = inbound
        self.outbound = outbound
        self.readLimit = readLimit
        self.writeLimit = writeLimit
    }
    func write(_ bytes: [UInt8]) -> Int {
        operations += 1
        let n = min(bytes.count, writeLimit, outbound.capacity - outbound.bytes.count)
        if n == 0 { blockedWrites += 1 }
        outbound.bytes.append(contentsOf: bytes.prefix(n))
        return n
    }
    func read(maxBytes: Int) -> LabRead {
        operations += 1
        let n = min(maxBytes, readLimit, inbound.bytes.count)
        guard n > 0 else { return .wouldBlock }
        let bytes = Array(inbound.bytes.prefix(n))
        inbound.bytes.removeFirst(n)
        return .bytes(bytes)
    }
}

private enum FixtureFailure: Error { case io }
private final class ScriptedPort: LabPort {
    var reads: [LabRead] = []
    var writeResult: Int?
    var throwsIO = false
    private(set) var calls = 0
    func write(_ bytes: [UInt8]) throws -> Int {
        calls += 1
        if throwsIO { throw FixtureFailure.io }
        return writeResult ?? bytes.count
    }
    func read(maxBytes: Int) throws -> LabRead {
        calls += 1
        if throwsIO { throw FixtureFailure.io }
        return reads.isEmpty ? .wouldBlock : reads.removeFirst()
    }
}

final class LabSessionTests: XCTestCase {
    private func opened(_ role: LabRole = .initiator, size: LabSize = .small) -> LabSession {
        let token = UUID()
        var run = LabSession(generation: token, role: role, size: size, nowMS: 0)
        run.linkConnected(generation: token, nowMS: 1)
        run.channelOpened(generation: token, nowMS: 2)
        return run
    }

    func testDuplexAllFixtureSizesWithPartialReadsWritesAndBackpressure() {
        for size in LabSize.allCases {
            let a = Pipe(capacity: 37), b = Pipe(capacity: 37)
            let client = DuplexPort(inbound: b, outbound: a, readLimit: 11, writeLimit: 23)
            let server = DuplexPort(inbound: a, outbound: b, readLimit: 13, writeLimit: 19)
            var initiator = opened(.initiator, size: size)
            var responder = opened(.responder, size: size)
            let i = initiator.generation, r = responder.generation
            for step in 3...9_000 {
                initiator.pump(generation: i, nowMS: UInt64(step), port: client)
                // Deliberately delay consumer readiness to fill the bounded pipe.
                if step.isMultiple(of: 3) {
                    responder.pump(generation: r, nowMS: UInt64(step), port: server)
                }
                XCTAssertLessThanOrEqual(a.bytes.count, a.capacity)
                XCTAssertLessThanOrEqual(b.bytes.count, b.capacity)
                if initiator.outcome != nil && responder.outcome != nil { break }
            }
            XCTAssertEqual(initiator.outcome, .success)
            XCTAssertEqual(responder.outcome, .success)
            XCTAssertEqual(initiator.sent, size.rawValue)
            XCTAssertEqual(initiator.received, size.rawValue)
            XCTAssertEqual(responder.sent, size.rawValue)
            XCTAssertEqual(responder.received, size.rawValue)
            XCTAssertTrue(a.bytes.isEmpty && b.bytes.isEmpty)
            XCTAssertGreaterThan(client.blockedWrites, 0)
            XCTAssertTrue(initiator.takeCleanupRequest(generation: i))
            XCTAssertFalse(initiator.takeCleanupRequest(generation: i))
            XCTAssertTrue(responder.takeCleanupRequest(generation: r))
        }
    }

    func testNoIOBeforeLinkAndChannelOrAfterStaleCallback() {
        let token = UUID(), stale = UUID(), port = ScriptedPort()
        var run = LabSession(generation: token, role: .initiator, size: .small, nowMS: 0)
        run.channelOpened(generation: token, nowMS: 1)
        run.pump(generation: token, nowMS: 2, port: port)
        XCTAssertEqual(run.phase, .awaitingLink)
        run.linkConnected(generation: stale, nowMS: 100_000)
        run.linkConnected(generation: token, nowMS: 3)
        run.pump(generation: token, nowMS: 4, port: port)
        run.channelOpened(generation: stale, nowMS: 0)
        XCTAssertEqual(run.phase, .awaitingChannel)
        XCTAssertEqual(port.calls, 0)
        run.channelOpened(generation: token, nowMS: 5)
        run.pump(generation: stale, nowMS: 100_000, port: port)
        XCTAssertEqual(port.calls, 0)
        run.pump(generation: token, nowMS: 6, port: port)
        XCTAssertEqual(port.calls, 1)
        XCTAssertEqual(run.sent, 64)
        XCTAssertNil(run.outcome)
    }

    func testIndependentDeadlineForEveryPhaseAndNoExtensionByDuplicates() {
        let token = UUID()
        var link = LabSession(generation: token, role: .initiator, size: .small, nowMS: 0)
        link.tick(generation: token, nowMS: 10_000)
        XCTAssertEqual(link.outcome, .linkTimeout)
        XCTAssertTrue(link.takeCleanupRequest(generation: token))

        var channel = LabSession(generation: token, role: .initiator, size: .small, nowMS: 0)
        channel.linkConnected(generation: token, nowMS: 2)
        channel.linkConnected(generation: token, nowMS: 9_000)
        channel.tick(generation: token, nowMS: 10_002)
        XCTAssertEqual(channel.outcome, .channelTimeout)

        var transfer = opened()
        let t = transfer.generation, port = ScriptedPort()
        port.writeResult = 0
        transfer.pump(generation: t, nowMS: 9_000, port: port)
        XCTAssertNil(transfer.outcome)
        transfer.channelOpened(generation: t, nowMS: 9_999)
        transfer.tick(generation: t, nowMS: 10_002)
        XCTAssertEqual(transfer.outcome, .transferTimeout)
        XCTAssertEqual(transfer.sent, 0)
        XCTAssertTrue(transfer.takeCleanupRequest(generation: t))
        transfer.pump(generation: t, nowMS: 10_003, port: port)
        XCTAssertEqual(port.calls, 1)
    }

    func testCancellationAndDisconnectFenceTerminalIOAndCleanup() {
        for cancel in [true, false] {
            var run = opened()
            let t = run.generation, port = ScriptedPort()
            if cancel { run.cancel(generation: t, nowMS: 3) }
            else { run.disconnect(generation: t, nowMS: 3) }
            XCTAssertEqual(run.outcome, cancel ? .cancelled : .disconnected)
            XCTAssertFalse(run.takeCleanupRequest(generation: UUID()))
            XCTAssertTrue(run.takeCleanupRequest(generation: t))
            run.channelOpened(generation: t, nowMS: 4)
            run.pump(generation: t, nowMS: 5, port: port)
            XCTAssertEqual(port.calls, 0)
            XCTAssertFalse(run.takeCleanupRequest(generation: t))
        }
    }

    func testBadCountsAndIOFailureAreTerminal() {
        for count in [-1, 65] {
            var run = opened()
            let port = ScriptedPort()
            port.writeResult = count
            run.pump(generation: run.generation, nowMS: 3, port: port)
            XCTAssertEqual(run.outcome, .invalidCount)
            XCTAssertEqual(run.sent, 0)
        }
        var run = opened()
        let port = ScriptedPort()
        port.throwsIO = true
        run.pump(generation: run.generation, nowMS: 3, port: port)
        XCTAssertEqual(run.outcome, .ioError)
        XCTAssertTrue(run.takeCleanupRequest(generation: run.generation))
    }

    func testResponderNeverReflectsUnverifiedData() {
        let cases: [(LabRead, LabOutcome)] = [
            (.end, .prematureEOF),
            (.bytes([]), .invalidCount),
            (.bytes(Array(repeating: 17, count: 65)), .invalidCount),
            (.bytes([0]), .unexpectedPayload)
        ]
        for (read, outcome) in cases {
            var run = opened(.responder)
            let port = ScriptedPort()
            port.reads = [read]
            run.pump(generation: run.generation, nowMS: 3, port: port)
            XCTAssertEqual(run.outcome, outcome)
            XCTAssertEqual(run.sent, 0)
            XCTAssertEqual(run.received, 0)
            XCTAssertEqual(port.calls, 1)
        }
    }

    func testRejectReorderedOrRepeatedWholeChunk() {
        let first = (0..<LabSession.chunkLimit).map(LabSession.fixtureByte(at:))
        let second = (LabSession.chunkLimit..<(2 * LabSession.chunkLimit)).map(LabSession.fixtureByte(at:))
        XCTAssertNotEqual(first, second)
        for chunks in [[second], [first, first]] {
            var run = opened(.responder, size: .medium)
            let token = run.generation, port = ScriptedPort()
            port.reads = chunks.map { .bytes($0) }
            for i in chunks.indices {
                run.pump(generation: token, nowMS: UInt64(3 + i), port: port)
            }
            XCTAssertEqual(run.outcome, .unexpectedPayload)
            XCTAssertEqual(run.sent, 0)
            XCTAssertTrue(run.takeCleanupRequest(generation: token))
        }
    }

    func testClockRegressionAndSanitizedStageEvidence() {
        let token = UUID(), port = ScriptedPort()
        var run = LabSession(generation: token, role: .initiator, size: .small, nowMS: 100)
        run.linkConnected(generation: token, nowMS: 120)
        run.channelOpened(generation: token, nowMS: 150)
        run.tick(generation: token, nowMS: 149)
        run.pump(generation: token, nowMS: 151, port: port)
        XCTAssertEqual(run.outcome, .clockRegression)
        XCTAssertEqual(run.linkElapsedMS, 20)
        XCTAssertEqual(run.channelElapsedMS, 30)
        XCTAssertEqual(run.totalElapsedMS, 50)
        XCTAssertEqual(port.calls, 0)
        XCTAssertFalse(run.report.contains(token.uuidString))
        XCTAssertTrue(run.report.contains("meta-transport=not-tested"))
        XCTAssertTrue(run.report.contains("wake-and-power=not-tested"))
    }

    func testFoundationMemoryStreamsAndIdempotentClose() throws {
        let input = InputStream(data: Data([17, 48, 79]))
        let output = OutputStream.toMemory()
        input.open()
        output.open()
        let port = FoundationStreamPort(input: input, output: output)
        XCTAssertEqual(try port.read(maxBytes: 2), .bytes([17, 48]))
        XCTAssertEqual(try port.write([17, 48]), 2)
        XCTAssertEqual(try port.read(maxBytes: 2), .bytes([79]))
        XCTAssertEqual(output.property(forKey: .dataWrittenToMemoryStreamKey) as? Data, Data([17, 48]))
        XCTAssertThrowsError(try port.read(maxBytes: LabSession.chunkLimit + 1))
        XCTAssertThrowsError(try port.write([]))
        port.close()
        port.close()
        XCTAssertTrue(port.isClosed)
        XCTAssertThrowsError(try port.write([17]))
    }
}
