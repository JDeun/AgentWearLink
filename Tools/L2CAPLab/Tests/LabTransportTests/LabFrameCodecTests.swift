import Foundation
import XCTest
@testable import LabTransport

final class LabFrameCodecTests: XCTestCase {
    private func frame(_ sequence: UInt32 = 1, size: Int = 64, correlation: UInt32 = 17,
                       kind: LabFrameKind = .request) -> LabFrame {
        LabFrame(kind: kind, sequence: sequence, correlation: correlation,
                 payload: (0..<size).map(LabSession.fixtureByte(at:)))
    }

    private func assertError(_ expected: LabFrameError, _ operation: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? LabFrameError, expected, file: file, line: line)
        }
    }

    func testCRCStandardVectorAndFixedHeader() throws {
        XCTAssertEqual(LabFrameCodec.checksum(Array("123456789".utf8)), 0xCBF43926)
        let value = LabFrame(kind: .response, sequence: 1, correlation: 0x01020304, payload: [0xAB])
        let bytes = try LabFrameCodec.encode(value)
        XCTAssertEqual(Array(bytes.prefix(16)),
                       [0x41, 0x57, 0x4C, 0x46, 1, 2, 0, 1, 0, 0, 0, 1, 1, 2, 3, 4])
        // Fixed full-wire golden vector, independently calculated with a table CRC.
        XCTAssertEqual(bytes, [
            0x41, 0x57, 0x4C, 0x46, 1, 2, 0, 1, 0, 0, 0, 1, 1, 2, 3, 4,
            0xAB, 0xB5, 0xAE, 0x1E, 0x42
        ])
        let token = UUID()
        var parser = LabFrameDecoder(generation: token)
        XCTAssertEqual(try parser.ingest(bytes[...], generation: token), bytes.count)
        XCTAssertEqual(try parser.take(generation: token), value)
        XCTAssertEqual(parser.bufferedBytes, 0)
    }

    func testEverySplitAndOneByteFragmentation() throws {
        let token = UUID(), value = frame()
        let bytes = try LabFrameCodec.encode(value)
        for split in 0...bytes.count {
            var parser = LabFrameDecoder(generation: token)
            XCTAssertEqual(try parser.ingest(bytes.prefix(split), generation: token), split)
            if split < bytes.count { XCTAssertFalse(parser.hasFrame) }
            XCTAssertEqual(try parser.ingest(bytes.dropFirst(split), generation: token), bytes.count - split)
            XCTAssertEqual(try parser.take(generation: token), value)
        }
        let large = frame(size: LabFrameCodec.maxPayloadBytes)
        let wire = try LabFrameCodec.encode(large)
        var parser = LabFrameDecoder(generation: token)
        for index in wire.indices {
            XCTAssertEqual(try parser.ingest(wire[index...index], generation: token), 1)
            XCTAssertLessThanOrEqual(parser.bufferedBytes, LabFrameCodec.maxFrameBytes)
        }
        XCTAssertEqual(try parser.take(generation: token), large)
        XCTAssertEqual(parser.bufferedBytes, 0)
    }

    func testCoalescedFramesPreserveExactUnconsumedSuffix() throws {
        let token = UUID(), first = frame(1), second = frame(2, size: 1024)
        let a = try LabFrameCodec.encode(first), b = try LabFrameCodec.encode(second)
        let all = a + b
        var parser = LabFrameDecoder(generation: token)
        XCTAssertEqual(try parser.ingest(all[...], generation: token), a.count)
        XCTAssertTrue(parser.hasFrame)
        XCTAssertEqual(parser.nextReadLimit, 0)
        XCTAssertEqual(try parser.ingest(all.dropFirst(a.count), generation: token), 0)
        XCTAssertEqual(try parser.take(generation: token), first)
        XCTAssertEqual(try parser.ingest(all.dropFirst(a.count), generation: token), b.count)
        XCTAssertEqual(try parser.take(generation: token), second)
        XCTAssertNil(try parser.take(generation: token))
    }

    func testRejectInvalidHeaderBeforeBodyAndNeverResynchronize() throws {
        let token = UUID(), good = try LabFrameCodec.encode(frame())
        let cases: [(Int, UInt8, LabFrameError)] = [
            (0, 0, .invalidMagic), (4, 2, .unsupportedVersion), (5, 9, .invalidKind),
            (6, 255, .invalidLength), (7, 0, .invalidLength), (11, 2, .invalidSequence),
            (15, 0, .invalidCorrelation)
        ]
        for (index, byte, error) in cases {
            var parser = LabFrameDecoder(generation: token)
            var header = Array(good.prefix(16))
            header[index] = byte
            XCTAssertEqual(try parser.ingest(header.prefix(15), generation: token), 15)
            assertError(error) { _ = try parser.ingest(header.suffix(1), generation: token) }
            XCTAssertEqual(parser.failure, error)
            XCTAssertEqual(parser.bufferedBytes, 0)
            XCTAssertFalse(parser.hasFrame)
            assertError(error) { _ = try parser.ingest(good[...], generation: token) }
        }
    }

    func testCorruptionIncludesHeaderAndTrailerAndFailsClosed() throws {
        let token = UUID(), good = try LabFrameCodec.encode(frame())
        for index in [15, 16, good.count - 1] {
            var parser = LabFrameDecoder(generation: token)
            var bad = good
            bad[index] ^= 1
            assertError(.badChecksum) { _ = try parser.ingest(bad[...], generation: token) }
            XCTAssertEqual(parser.bufferedBytes, 0)
            assertError(.badChecksum) { _ = try parser.take(generation: token) }
        }
    }

    func testDuplicateSkippedAndExhaustedSequence() throws {
        let token = UUID(), first = try LabFrameCodec.encode(frame(1))
        var parser = LabFrameDecoder(generation: token)
        _ = try parser.ingest(first[...], generation: token)
        _ = try parser.take(generation: token)
        assertError(.invalidSequence) { _ = try parser.ingest(first[...], generation: token) }
        var skip = LabFrameDecoder(generation: token)
        let third = try LabFrameCodec.encode(frame(3))
        assertError(.invalidSequence) { _ = try skip.ingest(third[...], generation: token) }
        var capped = LabFrameDecoder(generation: token)
        for n in 1...LabFrameCodec.maxSequence {
            let f = frame(n, size: 1), wire = try LabFrameCodec.encode(f)
            _ = try capped.ingest(wire[...], generation: token)
            XCTAssertEqual(try capped.take(generation: token), f)
        }
        assertError(.sequenceExhausted) { _ = try capped.ingest(first[...], generation: token) }
    }

    func testEOFMidHeaderBodyAndChecksumAndCleanBoundary() throws {
        let token = UUID(), value = frame(), wire = try LabFrameCodec.encode(value)
        for n in 1..<wire.count {
            var parser = LabFrameDecoder(generation: token)
            _ = try parser.ingest(wire.prefix(n), generation: token)
            assertError(.truncatedFrame) { try parser.endOfInput(generation: token) }
            XCTAssertEqual(parser.bufferedBytes, 0)
            XCTAssertFalse(parser.hasFrame)
        }
        var ready = LabFrameDecoder(generation: token)
        _ = try ready.ingest(wire[...], generation: token)
        try ready.endOfInput(generation: token)
        try ready.endOfInput(generation: token)
        XCTAssertTrue(ready.inputEnded)
        XCTAssertEqual(try ready.take(generation: token), value)
        assertError(.inputEnded) { _ = try ready.ingest(wire[...], generation: token) }
    }

    func testStaleGenerationAndRetirementClearPendingAndReady() throws {
        let token = UUID(), stale = UUID(), value = frame(), wire = try LabFrameCodec.encode(value)
        var parser = LabFrameDecoder(generation: token)
        _ = try parser.ingest(wire.prefix(5), generation: token)
        assertError(.staleGeneration) { _ = try parser.ingest(wire.dropFirst(5), generation: stale) }
        parser.retire(generation: stale)
        XCTAssertEqual(parser.bufferedBytes, 5)
        _ = try parser.ingest(wire.dropFirst(5), generation: token)
        parser.retire(generation: token)
        XCTAssertEqual(parser.bufferedBytes, 0)
        XCTAssertFalse(parser.hasFrame)
        assertError(.retired) { _ = try parser.take(generation: token) }
        var fresh = LabFrameDecoder(generation: stale)
        _ = try fresh.ingest(wire[...], generation: stale)
        XCTAssertEqual(try fresh.take(generation: stale), value)
    }

    func testEncodeLimitsAndCorrelationMatching() throws {
        assertError(.invalidLength) { _ = try LabFrameCodec.encode(frame(size: 0)) }
        assertError(.invalidLength) { _ = try LabFrameCodec.encode(frame(size: 4097)) }
        assertError(.invalidSequence) { _ = try LabFrameCodec.encode(frame(0)) }
        assertError(.invalidSequence) { _ = try LabFrameCodec.encode(frame(1025)) }
        assertError(.invalidCorrelation) { _ = try LabFrameCodec.encode(frame(correlation: 0)) }
        let request = frame(1)
        XCTAssertTrue(frame(2, kind: .response).isResponse(to: request))
        XCTAssertFalse(frame(2, correlation: 18, kind: .response).isResponse(to: request))
        XCTAssertFalse(frame(1).isResponse(to: request))
    }
}
