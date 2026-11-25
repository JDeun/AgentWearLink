import Foundation
import XCTest
@testable import LabTransport

private final class FramePipe {
    var bytes: [UInt8] = []
    let capacity = 37
}
private final class FrameDuplexPort: LabPort {
    let inbound: FramePipe
    let outbound: FramePipe
    var reads = 0
    var writes = 0
    var blocked = 0
    var maxRequest = 0

    init(inbound: FramePipe, outbound: FramePipe) {
        self.inbound = inbound
        self.outbound = outbound
    }
    func write(_ bytes: [UInt8]) -> Int {
        writes += 1
        maxRequest = max(maxRequest, bytes.count)
        let count = min(23, bytes.count, outbound.capacity - outbound.bytes.count)
        if count == 0 { blocked += 1 }
        outbound.bytes.append(contentsOf: bytes.prefix(count))
        return count
    }
    func read(maxBytes: Int) -> LabRead {
        reads += 1
        maxRequest = max(maxRequest, maxBytes)
        let count = min(11, maxBytes, inbound.bytes.count)
        guard count > 0 else { return .wouldBlock }
        let bytes = Array(inbound.bytes.prefix(count))
        inbound.bytes.removeFirst(count)
        return .bytes(bytes)
    }
}
private enum InjectedFrameIO: Error { case failed }
private final class FrameScriptPort: LabPort {
    var nextRead: LabRead = .wouldBlock
    var nextWrite: Int?
    var throwsIO = false
    var calls = 0
    func write(_ bytes: [UInt8]) throws -> Int {
        calls += 1
        if throwsIO { throw InjectedFrameIO.failed }
        return nextWrite ?? bytes.count
    }
    func read(maxBytes: Int) throws -> LabRead {
        calls += 1
        if throwsIO { throw InjectedFrameIO.failed }
        return nextRead
    }
}

final class LabFramedTransportTests: XCTestCase {
    private func assertError(_ expected: LabFrameError, _ operation: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? LabFrameError, expected, file: file, line: line)
        }
    }

    /// Exercises the real codec and LabPort adapter in both directions,
    /// independently generated synthetic payloads, repeated messages, no BLE.
    func testThreeSizedRoundTripsOverBoundedPartialDuplex() throws {
        let a = FramePipe(), b = FramePipe(), c = UUID(), s = UUID()
        let cp = FrameDuplexPort(inbound: b, outbound: a)
        let sp = FrameDuplexPort(inbound: a, outbound: b)
        var client = LabFramedTransport(generation: c), server = LabFramedTransport(generation: s)
        for (index, size) in LabSize.allCases.enumerated() {
            let seq = UInt32(index + 1), correlation = seq + 100
            let payload = (0..<size.rawValue).map(LabSession.fixtureByte(at:))
            let request = LabFrame(kind: .request, sequence: seq, correlation: correlation, payload: payload)
            XCTAssertEqual(try client.enqueue(kind: .request, correlation: correlation, payload: payload, generation: c), seq)
            XCTAssertNil(try client.enqueue(kind: .request, correlation: 999, payload: [0], generation: c))
            var answered = false
            var response: LabFrame?
            for tick in 0..<20_000 {
                _ = try client.pumpWrite(generation: c, port: cp)
                if tick.isMultiple(of: 3) {
                    _ = try server.pumpRead(generation: s, port: sp)
                    if let received = try server.take(generation: s) {
                        XCTAssertFalse(answered)
                        XCTAssertEqual(received, request)
                        // Not arbitrary payload reflection.
                        let fixture = (0..<size.rawValue).map(LabSession.fixtureByte(at:))
                        XCTAssertEqual(try server.enqueue(kind: .response, correlation: received.correlation,
                                                          payload: fixture, generation: s), seq)
                        answered = true
                    }
                    _ = try server.pumpWrite(generation: s, port: sp)
                }
                _ = try client.pumpRead(generation: c, port: cp)
                XCTAssertLessThanOrEqual(a.bytes.count, a.capacity)
                XCTAssertLessThanOrEqual(b.bytes.count, b.capacity)
                XCTAssertLessThanOrEqual(client.bufferedBytes, 2 * LabFrameCodec.maxFrameBytes)
                XCTAssertLessThanOrEqual(server.bufferedBytes, 2 * LabFrameCodec.maxFrameBytes)
                if let received = try client.take(generation: c) {
                    response = received
                    break
                }
            }
            XCTAssertTrue(answered)
            let reply = try XCTUnwrap(response)
            XCTAssertTrue(reply.isResponse(to: request))
            XCTAssertEqual(reply.sequence, seq)
            XCTAssertEqual(reply.payload, payload)
            XCTAssertFalse(client.hasPendingWrite)
            XCTAssertFalse(server.hasPendingWrite)
            XCTAssertTrue(a.bytes.isEmpty && b.bytes.isEmpty)
        }
        XCTAssertGreaterThan(cp.blocked, 0)
        XCTAssertLessThanOrEqual(cp.maxRequest, LabSession.chunkLimit)
        XCTAssertLessThanOrEqual(sp.maxRequest, LabSession.chunkLimit)
    }

    func testReaderDoesNotOverreadAndBackpressurePerFrame() throws {
        let token = UUID(), a = FramePipe(), b = FramePipe()
        let port = FrameDuplexPort(inbound: a, outbound: b)
        var transport = LabFramedTransport(generation: token)
        let first = LabFrame(kind: .request, sequence: 1, correlation: 1, payload: [1])
        let second = LabFrame(kind: .request, sequence: 2, correlation: 2, payload: [2])
        let wire = try LabFrameCodec.encode(first) + LabFrameCodec.encode(second)
        a.bytes = wire // deliberate coalesced read source for this test only
        for _ in 0..<10 where !transport.hasFrame {
            _ = try transport.pumpRead(generation: token, port: port)
        }
        XCTAssertTrue(transport.hasFrame)
        let calls = port.reads
        XCTAssertEqual(try transport.pumpRead(generation: token, port: port), .idle)
        XCTAssertEqual(port.reads, calls)
        XCTAssertEqual(a.bytes, try LabFrameCodec.encode(second))
        XCTAssertEqual(try transport.take(generation: token), first)
        for _ in 0..<10 where !transport.hasFrame {
            _ = try transport.pumpRead(generation: token, port: port)
        }
        XCTAssertEqual(try transport.take(generation: token), second)
        XCTAssertTrue(a.bytes.isEmpty)
    }

    func testInvalidCountsAndIOPoisonBothDirections() throws {
        let token = UUID()
        for bad in [-1, 100] {
            let port = FrameScriptPort()
            var link = LabFramedTransport(generation: token)
            _ = try link.enqueue(kind: .request, correlation: 1, payload: [1], generation: token)
            port.nextWrite = bad
            assertError(.invalidIOCount) { _ = try link.pumpWrite(generation: token, port: port) }
            XCTAssertEqual(link.bufferedBytes, 0)
            XCTAssertEqual(link.failure, .invalidIOCount)
            assertError(.invalidIOCount) { _ = try link.pumpRead(generation: token, port: port) }
            XCTAssertEqual(port.calls, 1)
        }
        for bad in [LabRead.bytes([]), .bytes(Array(repeating: 0, count: 17))] {
            let port = FrameScriptPort()
            port.nextRead = bad
            var link = LabFramedTransport(generation: token)
            _ = try link.enqueue(kind: .request, correlation: 1, payload: [1], generation: token)
            assertError(.invalidIOCount) { _ = try link.pumpRead(generation: token, port: port) }
            XCTAssertEqual(link.bufferedBytes, 0)
        }
        let port = FrameScriptPort()
        port.throwsIO = true
        var link = LabFramedTransport(generation: token)
        assertError(.ioFailure) { _ = try link.pumpRead(generation: token, port: port) }
        XCTAssertEqual(link.failure, .ioFailure)
    }

    func testEOFAndMalformedInputDiscardPendingTX() throws {
        let token = UUID(), port = FrameScriptPort()
        var link = LabFramedTransport(generation: token)
        _ = try link.enqueue(kind: .request, correlation: 1, payload: [1], generation: token)
        port.nextRead = .bytes([0x41])
        XCTAssertEqual(try link.pumpRead(generation: token, port: port), .progress(1))
        port.nextRead = .end
        assertError(.truncatedFrame) { _ = try link.pumpRead(generation: token, port: port) }
        XCTAssertEqual(link.bufferedBytes, 0)
        XCTAssertFalse(link.hasPendingWrite)
        var clean = LabFramedTransport(generation: token)
        XCTAssertEqual(try clean.pumpRead(generation: token, port: port), .end)
        let calls = port.calls
        XCTAssertEqual(try clean.pumpRead(generation: token, port: port), .end)
        XCTAssertEqual(port.calls, calls)
        XCTAssertTrue(clean.inputEnded)
    }

    func testZeroWriteStaleCallbacksAndRetireWithoutReplay() throws {
        let token = UUID(), stale = UUID(), port = FrameScriptPort()
        var link = LabFramedTransport(generation: token)
        assertError(.invalidCorrelation) {
            _ = try link.enqueue(kind: .request, correlation: 0, payload: [1], generation: token)
        }
        XCTAssertEqual(try link.enqueue(kind: .request, correlation: 1, payload: [1], generation: token), 1)
        port.nextWrite = 0
        XCTAssertEqual(try link.pumpWrite(generation: token, port: port), .wouldBlock)
        let retained = link.bufferedBytes
        assertError(.staleGeneration) { _ = try link.pumpWrite(generation: stale, port: port) }
        link.retire(generation: stale)
        XCTAssertEqual(link.bufferedBytes, retained)
        XCTAssertEqual(port.calls, 1)
        link.retire(generation: token)
        link.retire(generation: token)
        XCTAssertEqual(link.bufferedBytes, 0)
        assertError(.retired) { _ = try link.pumpRead(generation: token, port: port) }
        XCTAssertEqual(port.calls, 1)
        var fresh = LabFramedTransport(generation: stale)
        XCTAssertEqual(try fresh.enqueue(kind: .request, correlation: 1, payload: [2], generation: stale), 1)
    }
}
