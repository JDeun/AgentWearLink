import Foundation
import XCTest
@testable import LabTransport

private final class SessionPipe {
    let capacity = 37
    var bytes: [UInt8] = []
}

private final class SessionDuplexPort: LabPort {
    let inbound: SessionPipe
    let outbound: SessionPipe
    private(set) var calls = 0
    private(set) var blockedWrites = 0
    private(set) var maxRequest = 0

    init(inbound: SessionPipe, outbound: SessionPipe) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func write(_ bytes: [UInt8]) -> Int {
        calls += 1
        maxRequest = max(maxRequest, bytes.count)
        let n = min(17, bytes.count, outbound.capacity - outbound.bytes.count)
        if n == 0 { blockedWrites += 1 }
        outbound.bytes.append(contentsOf: bytes.prefix(n))
        return n
    }

    func read(maxBytes: Int) -> LabRead {
        calls += 1
        maxRequest = max(maxRequest, maxBytes)
        let n = min(11, maxBytes, inbound.bytes.count)
        guard n > 0 else { return .wouldBlock }
        let result = Array(inbound.bytes.prefix(n))
        inbound.bytes.removeFirst(n)
        return .bytes(result)
    }
}

private final class SessionScriptPort: LabPort {
    var incoming: [UInt8] = []
    var writeLimit = 256
    var eof = false
    var calls = 0
    var written = 0

    func write(_ bytes: [UInt8]) -> Int {
        calls += 1
        let n = min(writeLimit, bytes.count)
        written += n
        return n
    }

    func read(maxBytes: Int) -> LabRead {
        calls += 1
        let n = min(maxBytes, incoming.count)
        if n == 0 { return eof ? .end : .wouldBlock }
        let bytes = Array(incoming.prefix(n))
        incoming.removeFirst(n)
        return .bytes(bytes)
    }
}

final class LabMessageSessionTests: XCTestCase {
    private func fixture(_ size: LabSize) -> [UInt8] {
        (0..<size.rawValue).map(LabSession.fixtureByte(at:))
    }

    private func wire(_ kind: LabFrameKind, _ sequence: UInt32, _ correlation: UInt32,
                      _ bytes: [UInt8]) throws -> [UInt8] {
        try LabFrameCodec.encode(LabFrame(kind: kind, sequence: sequence, correlation: correlation, payload: bytes))
    }

    private func acceptPayload(_ size: LabSize = .large) -> [UInt8] {
        LabMessageNegotiation.hello(maximumSize: size)
    }

    private func readyClient(_ port: SessionScriptPort, maximumSize: LabSize = .large,
                             acceptedSize: LabSize = .large) throws -> LabMessageSession {
        let token = UUID()
        var client = try LabMessageSession(generation: token, role: .initiator, maximumSize: maximumSize, nowMS: 0)
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 0), .notReady)
        client.pump(generation: token, nowMS: 1, port: port)
        XCTAssertEqual(client.phase, .awaitingAccept)
        port.incoming = try wire(.response, 1, 1, acceptPayload(acceptedSize))
        client.pump(generation: token, nowMS: 2, port: port)
        client.pump(generation: token, nowMS: 3, port: port)
        XCTAssertEqual(client.phase, .ready)
        return client
    }

    private func readyServer(_ port: SessionScriptPort, maximumSize: LabSize = .large) throws -> LabMessageSession {
        let token = UUID()
        var server = try LabMessageSession(generation: token, role: .responder, maximumSize: maximumSize, nowMS: 0)
        port.incoming = try wire(.request, 1, 1, acceptPayload())
        server.pump(generation: token, nowMS: 1, port: port)
        server.pump(generation: token, nowMS: 2, port: port)
        XCTAssertEqual(server.phase, .sendingAccept)
        server.pump(generation: token, nowMS: 3, port: port)
        XCTAssertEqual(server.phase, .ready)
        return server
    }

    private func deliver(_ bytes: [UInt8], to session: inout LabMessageSession,
                         port: SessionScriptPort, time: UInt64) {
        port.incoming = bytes
        for i in 0..<32 where !port.incoming.isEmpty && session.phase != .finished {
            session.pump(generation: session.generation, nowMS: time + UInt64(i), port: port)
        }
    }

    private func assertCleanup(_ session: inout LabMessageSession, _ reason: LabMessageOutcome,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.outcome, reason, file: file, line: line)
        XCTAssertEqual(session.phase, .finished, file: file, line: line)
        XCTAssertFalse(session.hasPendingRequest, file: file, line: line)
        XCTAssertEqual(session.bufferedBytes, 0, file: file, line: line)
        XCTAssertFalse(session.takeCleanupRequest(generation: UUID()), file: file, line: line)
        let generation = session.generation
        XCTAssertTrue(session.takeCleanupRequest(generation: generation), file: file, line: line)
        XCTAssertFalse(session.takeCleanupRequest(generation: generation), file: file, line: line)
    }

    func testNegotiatedRepeatedRoundTripsOverActualFramedTransport() throws {
        let a = SessionPipe(), b = SessionPipe(), ct = UUID(), st = UUID()
        let cp = SessionDuplexPort(inbound: b, outbound: a)
        let sp = SessionDuplexPort(inbound: a, outbound: b)
        var client = try LabMessageSession(generation: ct, role: .initiator, nowMS: 0)
        var server = try LabMessageSession(generation: st, role: .responder, nowMS: 0)
        var now: UInt64 = 0
        for _ in 0..<1000 {
            now += 1
            client.pump(generation: ct, nowMS: now, port: cp)
            server.pump(generation: st, nowMS: now, port: sp)
            if client.phase == .ready && server.phase == .ready { break }
        }
        XCTAssertEqual(client.phase, .ready)
        XCTAssertEqual(server.phase, .ready)
        XCTAssertEqual(client.agreement, server.agreement)
        XCTAssertEqual(client.agreement?.version, 1)
        XCTAssertEqual(client.agreement?.capabilities, 1)
        XCTAssertEqual(client.agreement?.maximumPayload, 4096)

        for (index, size) in LabSize.allCases.enumerated() {
            let correlation = UInt32(index + 2)
            XCTAssertEqual(client.request(size: size, generation: ct, nowMS: now), .accepted(correlation))
            XCTAssertEqual(client.request(size: size, generation: ct, nowMS: now), .busy)
            for _ in 0..<9000 {
                now += 1
                client.pump(generation: ct, nowMS: now, port: cp)
                if now.isMultiple(of: 3) { server.pump(generation: st, nowMS: now, port: sp) }
                XCTAssertLessThanOrEqual(a.bytes.count, a.capacity)
                XCTAssertLessThanOrEqual(b.bytes.count, b.capacity)
                XCTAssertLessThanOrEqual(client.bufferedBytes, 2 * LabFrameCodec.maxFrameBytes)
                XCTAssertLessThanOrEqual(server.bufferedBytes, 2 * LabFrameCodec.maxFrameBytes)
                if client.hasCompletion && server.phase == .ready { break }
            }
            XCTAssertTrue(client.hasCompletion)
            XCTAssertEqual(client.request(size: .small, generation: ct, nowMS: now), .busy)
            XCTAssertNil(client.takeCompletion(generation: st))
            let done = try XCTUnwrap(client.takeCompletion(generation: ct))
            XCTAssertEqual(done.correlation, correlation)
            XCTAssertEqual(done.fixtureBytes, size.rawValue)
            XCTAssertEqual(done.resolution, .verified)
            XCTAssertNil(client.takeCompletion(generation: ct))
            XCTAssertEqual(client.completedRequests, index + 1)
            XCTAssertEqual(server.completedRequests, index + 1)
            XCTAssertTrue(a.bytes.isEmpty && b.bytes.isEmpty)
        }
        XCTAssertGreaterThan(cp.blockedWrites, 0)
        XCTAssertLessThanOrEqual(cp.maxRequest, LabSession.chunkLimit)
        XCTAssertLessThanOrEqual(sp.maxRequest, LabSession.chunkLimit)
        XCTAssertTrue(client.close(generation: ct, nowMS: now))
        XCTAssertTrue(server.close(generation: st, nowMS: now))
        assertCleanup(&client, .closed)
        assertCleanup(&server, .closed)
        XCTAssertTrue(client.report.contains("completion-basis=verified-response"))
        XCTAssertTrue(server.report.contains("completion-basis=local-write-accepted"))
        XCTAssertTrue(server.report.contains("physical-evidence=not-tested"))
        XCTAssertFalse(client.report.contains(ct.uuidString))
    }

    func testNegotiationSelectsIntersectionAndRejectsUnsupportedFixtureWithoutIDConsumption() throws {
        let selected = try LabMessageNegotiation.select(hello: [1, 3, 0x80, 1, 0x10, 0], maximumSize: .medium)
        XCTAssertEqual(selected.version, 1)
        XCTAssertEqual(selected.capabilities, 1)
        XCTAssertEqual(selected.maximumPayload, 1024)
        XCTAssertEqual(LabMessageNegotiation.acceptBytes(selected), [1, 1, 0, 1, 4, 0])
        let port = SessionScriptPort()
        var client = try readyClient(port, acceptedSize: .medium)
        let token = client.generation, calls = port.calls
        XCTAssertEqual(client.request(size: .large, generation: token, nowMS: 4), .unsupportedSize)
        XCTAssertEqual(client.request(size: .medium, generation: UUID(), nowMS: 900_000), .staleGeneration)
        XCTAssertEqual(port.calls, calls)
        XCTAssertEqual(client.request(size: .medium, generation: token, nowMS: 5), .accepted(2))
        XCTAssertFalse(client.close(generation: token, nowMS: 5))
    }

    func testMalformedOrUnsupportedNegotiationFailsClosed() throws {
        let cases: [([UInt8], LabMessageOutcome)] = [
            ([2, 3, 0, 1, 0x10, 0], .unsupportedVersion),
            ([1, 1, 0, 0, 0x10, 0], .unsupportedCapability),
            ([0, 1, 0, 1, 0x10, 0], .invalidNegotiation),
            ([2, 1, 0, 1, 0x10, 0], .invalidNegotiation),
            ([1, 1, 0, 1, 0, 63], .invalidNegotiation),
            ([1, 1, 0, 1, 0x10, 1], .invalidNegotiation),
            ([1, 1, 0, 1, 0x10], .invalidNegotiation)
        ]
        for (payload, outcome) in cases {
            let token = UUID(), port = SessionScriptPort()
            var server = try LabMessageSession(generation: token, role: .responder, nowMS: 0)
            deliver(try wire(.request, 1, 1, payload), to: &server, port: port, time: 1)
            XCTAssertNil(server.agreement)
            XCTAssertEqual(port.written, 0)
            assertCleanup(&server, outcome)
        }
        for (payload, outcome) in [
            ([1, 1, 0, 3, 0, 64] as [UInt8], LabMessageOutcome.unsupportedCapability),
            ([1, 2, 0, 1, 0, 64], .unsupportedVersion),
            ([1, 1, 0, 1, 4, 0], .invalidNegotiation)
        ] {
            let token = UUID(), port = SessionScriptPort()
            var client = try LabMessageSession(generation: token, role: .initiator, maximumSize: .small, nowMS: 0)
            client.pump(generation: token, nowMS: 1, port: port)
            deliver(try wire(.response, 1, 1, payload), to: &client, port: port, time: 2)
            assertCleanup(&client, outcome)
        }
    }

    func testWrongDirectionOrCorrelationDuringNegotiation() throws {
        for (kind, correlation, reason) in [
            (LabFrameKind.response, UInt32(1), LabMessageOutcome.unexpectedMessage),
            (.request, 2, .invalidCorrelation)
        ] {
            let token = UUID(), port = SessionScriptPort()
            var server = try LabMessageSession(generation: token, role: .responder, nowMS: 0)
            deliver(try wire(kind, 1, correlation, acceptPayload()), to: &server, port: port, time: 1)
            assertCleanup(&server, reason)
        }
    }

    func testWrongResponseCannotResolveAcceptedRequestAsSuccess() throws {
        var bad = fixture(.small)
        bad[10] ^= 1
        for (kind, correlation, payload, reason) in [
            (LabFrameKind.response, UInt32(3), fixture(.small), LabMessageOutcome.invalidCorrelation),
            (.request, 2, fixture(.small), .unexpectedMessage),
            (.response, 2, bad, .invalidPayload),
            (.response, 2, fixture(.medium), .invalidPayload)
        ] {
            let port = SessionScriptPort()
            var client = try readyClient(port)
            let token = client.generation
            XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 4), .accepted(2))
            client.pump(generation: token, nowMS: 5, port: port)
            deliver(try wire(kind, 2, correlation, payload), to: &client, port: port, time: 6)
            assertCleanup(&client, reason)
            let done = try XCTUnwrap(client.takeCompletion(generation: token))
            XCTAssertEqual(done.correlation, 2)
            XCTAssertEqual(done.fixtureBytes, 64)
            XCTAssertEqual(done.resolution, .failed(reason))
            XCTAssertNil(client.takeCompletion(generation: token))
            XCTAssertEqual(client.completedRequests, 0)
        }
    }

    func testResponderRejectsSkippedCorrelationAndNonFixtureBeforeWriting() throws {
        var bad = fixture(.small)
        bad[0] ^= 1
        for (kind, corr, payload, reason) in [
            (LabFrameKind.request, UInt32(3), fixture(.small), LabMessageOutcome.invalidCorrelation),
            (.request, 1, fixture(.small), .invalidCorrelation),
            (.response, 2, fixture(.small), .unexpectedMessage),
            (.request, 2, bad, .invalidPayload),
            (.request, 2, [UInt8(9)], .invalidPayload),
            (.request, 2, fixture(.large), .invalidPayload)
        ] {
            let port = SessionScriptPort()
            var server = try readyServer(port, maximumSize: .medium)
            let previous = port.written
            deliver(try wire(kind, 2, corr, payload), to: &server, port: port, time: 4)
            assertCleanup(&server, reason)
            XCTAssertEqual(port.written, previous)
            XCTAssertEqual(server.completedRequests, 0)
        }
    }

    func testDuplicateWhileIdlePreservesOnlyOriginalCompletion() throws {
        let port = SessionScriptPort()
        var client = try readyClient(port)
        let token = client.generation
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 4), .accepted(2))
        client.pump(generation: token, nowMS: 5, port: port)
        deliver(try wire(.response, 2, 2, fixture(.small)), to: &client, port: port, time: 6)
        XCTAssertTrue(client.hasCompletion)
        port.incoming = [0x41] // even a partial unsolicited frame is invalid when idle
        client.pump(generation: token, nowMS: 10, port: port)
        assertCleanup(&client, .unexpectedMessage)
        XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .verified)
        XCTAssertNil(client.takeCompletion(generation: token))
        XCTAssertEqual(client.completedRequests, 1)
    }

    func testLateResponseWithFreshFrameSequenceFailsNextCorrelation() throws {
        let port = SessionScriptPort()
        var client = try readyClient(port)
        let token = client.generation
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 4), .accepted(2))
        client.pump(generation: token, nowMS: 5, port: port)
        deliver(try wire(.response, 2, 2, fixture(.small)), to: &client, port: port, time: 6)
        XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .verified)
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 10), .accepted(3))
        client.pump(generation: token, nowMS: 11, port: port)
        deliver(try wire(.response, 3, 2, fixture(.small)), to: &client, port: port, time: 12)
        assertCleanup(&client, .invalidCorrelation)
        XCTAssertEqual(client.takeCompletion(generation: token)?.correlation, 3)
        XCTAssertEqual(client.completedRequests, 1)
    }

    func testNegotiationDeadlineIncludesSendingAndWaiting() throws {
        let token = UUID(), port = SessionScriptPort()
        var client = try LabMessageSession(generation: token, role: .initiator, nowMS: 0)
        port.writeLimit = 0
        XCTAssertEqual(client.pump(generation: token, nowMS: 9000, port: port), .wouldBlock)
        port.writeLimit = 256
        client.pump(generation: token, nowMS: 9999, port: port)
        XCTAssertEqual(client.phase, .awaitingAccept)
        client.tick(generation: token, nowMS: 10000)
        assertCleanup(&client, .negotiationTimeout)
        let calls = port.calls
        client.pump(generation: token, nowMS: 10001, port: port)
        XCTAssertEqual(port.calls, calls)

        let st = UUID()
        var server = try LabMessageSession(generation: st, role: .responder, nowMS: 0)
        port.incoming = [0x41]
        server.pump(generation: st, nowMS: 9999, port: port)
        server.tick(generation: st, nowMS: 10000)
        assertCleanup(&server, .negotiationTimeout)
    }

    func testPartialRequestTimeoutAndLateCallbacksDoNotReplay() throws {
        let port = SessionScriptPort()
        var client = try readyClient(port)
        let token = client.generation
        XCTAssertEqual(client.request(size: .large, generation: token, nowMS: 4), .accepted(2))
        port.writeLimit = 2
        XCTAssertEqual(client.pump(generation: token, nowMS: 10003, port: port), .progress(2))
        XCTAssertEqual(client.phase, .sendingRequest)
        client.tick(generation: UUID(), nowMS: UInt64.max)
        XCTAssertNil(client.outcome)
        client.tick(generation: token, nowMS: 10004)
        assertCleanup(&client, .requestTimeout)
        let calls = port.calls
        port.incoming = try wire(.response, 2, 2, fixture(.large))
        client.pump(generation: token, nowMS: 10005, port: port)
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 10006), .terminal)
        XCTAssertEqual(port.calls, calls)
        let done = try XCTUnwrap(client.takeCompletion(generation: token))
        XCTAssertEqual(done.elapsedMS, 10000)
        XCTAssertEqual(done.resolution, .failed(.requestTimeout))
        XCTAssertNil(client.takeCompletion(generation: token))
    }

    func testTargetedCancelAndDisconnectSettleExactlyOnce() throws {
        for shouldCancel in [true, false] {
            let port = SessionScriptPort()
            var client = try readyClient(port)
            let token = client.generation
            XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 4), .accepted(2))
            port.writeLimit = 1
            client.pump(generation: token, nowMS: 5, port: port)
            XCTAssertFalse(client.cancelRequest(correlation: 1, generation: token, nowMS: 900_000))
            XCTAssertFalse(client.cancelRequest(correlation: 2, generation: UUID(), nowMS: 900_000))
            XCTAssertNil(client.outcome)
            if shouldCancel { XCTAssertTrue(client.cancelRequest(correlation: 2, generation: token, nowMS: 6)) }
            else { client.disconnect(generation: token, nowMS: 6) }
            let reason: LabMessageOutcome = shouldCancel ? .cancelled : .disconnected
            assertCleanup(&client, reason)
            XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .failed(reason))
            client.cancel(generation: token, nowMS: 7)
            XCTAssertNil(client.takeCompletion(generation: token))
        }
    }

    func testResponderIdlePartialFrameAndResponseWriteDeadlines() throws {
        let port = SessionScriptPort()
        var server = try readyServer(port)
        let token = server.generation
        port.incoming = [0x41]
        server.pump(generation: token, nowMS: 10002, port: port)
        server.tick(generation: token, nowMS: 10003)
        assertCleanup(&server, .idleTimeout)
        var fresh = try readyServer(port)
        let ft = fresh.generation
        deliver(try wire(.request, 2, 2, fixture(.small)), to: &fresh, port: port, time: 4)
        XCTAssertEqual(fresh.phase, .sendingResponse)
        port.writeLimit = 0
        XCTAssertEqual(fresh.pump(generation: ft, nowMS: 10004, port: port), .wouldBlock)
        fresh.tick(generation: ft, nowMS: 10005)
        assertCleanup(&fresh, .requestTimeout)
        XCTAssertEqual(fresh.completedRequests, 0)
    }

    func testEOFMidFrameAndCleanEOFResolvePendingWithoutSuccess() throws {
        for partial in [false, true] {
            let port = SessionScriptPort()
            var client = try readyClient(port)
            let token = client.generation
            XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 4), .accepted(2))
            client.pump(generation: token, nowMS: 5, port: port)
            if partial {
                port.incoming = [0x41, 0x57]
                client.pump(generation: token, nowMS: 6, port: port)
            }
            port.eof = true
            client.pump(generation: token, nowMS: 7, port: port)
            let reason: LabMessageOutcome = partial ? .transportFailure : .endOfStream
            assertCleanup(&client, reason)
            XCTAssertEqual(client.frameFailure, partial ? .truncatedFrame : nil)
            XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .failed(reason))
            XCTAssertEqual(client.completedRequests, 0)
        }
    }

    func testTotalBudgetCannotBeRenewedBySuccessfulRequests() throws {
        let port = SessionScriptPort()
        var client = try readyClient(port)
        let token = client.generation
        for n in 1...6 {
            let t = UInt64(n * 9000), seq = UInt32(n + 1)
            XCTAssertEqual(client.request(size: .small, generation: token, nowMS: t), .accepted(seq))
            client.pump(generation: token, nowMS: t + 1, port: port)
            deliver(try wire(.response, seq, seq, fixture(.small)), to: &client, port: port, time: t + 2)
            XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .verified)
        }
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 59998), .accepted(8))
        client.pump(generation: token, nowMS: 59999, port: port)
        client.tick(generation: token, nowMS: 60000)
        assertCleanup(&client, .sessionTimeout)
        XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .failed(.sessionTimeout))
        XCTAssertEqual(client.completedRequests, 6)
    }

    func testMonotonicClockRegressionAndFreshGeneration() throws {
        let port = SessionScriptPort()
        var client = try readyClient(port)
        let token = client.generation
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: 4), .accepted(2))
        client.tick(generation: token, nowMS: 3)
        assertCleanup(&client, .clockRegression)
        let done = try XCTUnwrap(client.takeCompletion(generation: token))
        XCTAssertEqual(done.elapsedMS, 0)
        XCTAssertEqual(done.resolution, .failed(.clockRegression))
        var fresh = try LabMessageSession(generation: UUID(), role: .initiator, nowMS: 0)
        let before = port.calls
        fresh.pump(generation: token, nowMS: 999999, port: port)
        XCTAssertEqual(port.calls, before)
        XCTAssertEqual(fresh.phase, .sendingHello)
    }

    func testCorrelationAndFrameSequenceExhaustionNeverWrap() throws {
        let port = SessionScriptPort()
        var client = try readyClient(port)
        let token = client.generation
        var time: UInt64 = 4
        for correlation in UInt32(2)...LabFrameCodec.maxSequence {
            XCTAssertEqual(client.request(size: .small, generation: token, nowMS: time), .accepted(correlation))
            client.pump(generation: token, nowMS: time + 1, port: port)
            deliver(try wire(.response, correlation, correlation, fixture(.small)), to: &client, port: port, time: time + 2)
            XCTAssertEqual(client.takeCompletion(generation: token)?.resolution, .verified)
            time += 5
        }
        XCTAssertEqual(client.completedRequests, Int(LabFrameCodec.maxSequence) - 1)
        XCTAssertEqual(client.request(size: .small, generation: token, nowMS: time), .terminal)
        assertCleanup(&client, .sequenceExhausted)
        XCTAssertNil(client.takeCompletion(generation: token))
    }
}
