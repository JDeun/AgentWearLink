import XCTest

final class VoiceStreamConfigTests: XCTestCase {
    private let key = String(repeating: "k", count: 43)

    func testAcceptsHTTPSWithHostAndBuildsTheStreamURL() throws {
        let config = try XCTUnwrap(VoiceStreamConfig(url: "https://mini.tail1.ts.net:8445", key: key))
        XCTAssertEqual(config.streamURL.absoluteString, "https://mini.tail1.ts.net:8445/v1/audio/speech/stream")
        XCTAssertEqual(config.authorization, "Bearer \(key)")
    }

    func testTrailingSlashQueryAndWhitespaceAreDropped() throws {
        let config = try XCTUnwrap(VoiceStreamConfig(url: " https://mini.tail1.ts.net:8445/?x=1#f ", key: " \(key)\n"))
        XCTAssertEqual(config.streamURL.absoluteString, "https://mini.tail1.ts.net:8445/v1/audio/speech/stream")
        XCTAssertEqual(config.key, key)
    }

    func testRejectsPlainHTTPAndMissingHost() {
        XCTAssertNil(VoiceStreamConfig(url: "http://mini.tail1.ts.net:8445", key: key))
        XCTAssertNil(VoiceStreamConfig(url: "https://", key: key))
        XCTAssertNil(VoiceStreamConfig(url: "mini.tail1.ts.net:8445", key: key))
    }

    func testRejectsCredentialsInTheURL() {
        XCTAssertNil(VoiceStreamConfig(url: "https://user:pw@mini.tail1.ts.net:8445", key: key))
    }

    func testRejectsShortOrSpacedKeys() {
        XCTAssertNil(VoiceStreamConfig(url: "https://mini.tail1.ts.net:8445", key: "short"))
        XCTAssertNil(VoiceStreamConfig(url: "https://mini.tail1.ts.net:8445", key: String(repeating: "k", count: 20) + " " + String(repeating: "k", count: 20)))
    }

    func testKeyMayStartWithADash() throws {
        let dashed = "-" + String(repeating: "a", count: 42)
        XCTAssertEqual(LaunchArgument.rawValue(LaunchArgument.voiceStreamKey, in: ["App", "-AWLVoiceStreamKey", dashed]), dashed)
        XCTAssertNil(LaunchArgument.value(LaunchArgument.voiceStreamKey, in: ["App", "-AWLVoiceStreamKey", dashed]))
        XCTAssertNotNil(VoiceStreamConfig(url: "https://mini.tail1.ts.net:8445", key: dashed))
    }

    func testMissingKeyValueIsNil() {
        XCTAssertNil(LaunchArgument.rawValue(LaunchArgument.voiceStreamKey, in: ["App", "-AWLVoiceStreamKey"]))
        XCTAssertNil(LaunchArgument.rawValue(LaunchArgument.voiceStreamKey, in: ["App", "-AWLVoiceStreamKey", "  "]))
    }

    func testAnotherFlagTakenAsKeyFailsValidation() {
        let raw = LaunchArgument.rawValue(LaunchArgument.voiceStreamKey, in: ["App", "-AWLVoiceStreamKey", "-AWLSessionKey"])
        XCTAssertNil(raw.flatMap { VoiceStreamConfig(url: "https://mini.tail1.ts.net:8445", key: $0) })
    }
}

final class PCMSampleAssemblerTests: XCTestCase {
    func testWholeSamplesAreLittleEndian() {
        var assembler = PCMSampleAssembler()
        XCTAssertEqual(assembler.append(Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])), [1, 32767, -32768])
        XCTAssertFalse(assembler.hasDanglingByte)
    }

    func testASampleSplitAcrossChunksIsCarriedOver() {
        var assembler = PCMSampleAssembler()
        XCTAssertEqual(assembler.append(Data([0x34, 0x12, 0x78])), [0x1234])
        XCTAssertTrue(assembler.hasDanglingByte)
        XCTAssertEqual(assembler.append(Data([0x56])), [0x5678])
        XCTAssertEqual(assembler.append(Data([0xCD])), [])
        XCTAssertEqual(assembler.append(Data([0xAB, 0x02, 0x00])), [Int16(bitPattern: 0xABCD), 2])
        XCTAssertEqual(assembler.totalSamples, 4)
    }

    func testAnySplitGivesTheSameSamples() {
        let samples: [Int16] = (0..<500).map { Int16(truncatingIfNeeded: $0 * 977 - 30_000) }
        var bytes = Data()
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            bytes.append(UInt8(bits & 0xFF))
            bytes.append(UInt8(bits >> 8))
        }
        for chunk in [1, 3, 7, 64, 333, 1000] {
            var assembler = PCMSampleAssembler()
            var out: [Int16] = []
            var index = 0
            while index < bytes.count {
                let end = min(index + chunk, bytes.count)
                out += assembler.append(bytes.subdata(in: index..<end))
                index = end
            }
            XCTAssertEqual(out, samples, "chunk \(chunk)")
        }
    }

    func testEmptyChunkIsNothing() {
        var assembler = PCMSampleAssembler()
        XCTAssertEqual(assembler.append(Data()), [])
    }
}

final class StreamPolicyTests: XCTestCase {
    func testStartsAfterTheJitterBuffer() {
        XCTAssertFalse(StreamJitterPolicy.shouldStart(bufferedSeconds: 0.1, ended: false))
        XCTAssertTrue(StreamJitterPolicy.shouldStart(bufferedSeconds: 0.25, ended: false))
        XCTAssertTrue(StreamJitterPolicy.shouldStart(bufferedSeconds: 0.32, ended: false))
    }

    func testAShortSentenceStartsWhenItEnded() {
        XCTAssertTrue(StreamJitterPolicy.shouldStart(bufferedSeconds: 0.1, ended: true))
        XCTAssertFalse(StreamJitterPolicy.shouldStart(bufferedSeconds: 0, ended: true))
    }

    func testDeadlineKeepsTheFirstAudioWellUnderTheOldGatewayWait() {
        XCTAssertLessThanOrEqual(StreamJitterPolicy.firstAudioDeadline, .milliseconds(1500))
        XCTAssertGreaterThan(StreamJitterPolicy.firstAudioDeadline, .milliseconds(500))
    }

    func testRouteStartsAtTheBestAvailableVoice() {
        XCTAssertEqual(ReplyVoiceRoute.start(streamConfigured: true, gatewayAvailable: true), .stream)
        XCTAssertEqual(ReplyVoiceRoute.start(streamConfigured: true, gatewayAvailable: false), .stream)
        XCTAssertEqual(ReplyVoiceRoute.start(streamConfigured: false, gatewayAvailable: true), .gateway)
        XCTAssertEqual(ReplyVoiceRoute.start(streamConfigured: false, gatewayAvailable: false), .system)
    }

    func testFallbackOrderIsStreamThenGatewayThenSystem() {
        XCTAssertEqual(ReplyVoiceRoute.stream.next(gatewayAvailable: true), .gateway)
        XCTAssertEqual(ReplyVoiceRoute.stream.next(gatewayAvailable: false), .system)
        XCTAssertEqual(ReplyVoiceRoute.gateway.next(gatewayAvailable: true), .system)
        XCTAssertEqual(ReplyVoiceRoute.system.next(gatewayAvailable: true), .system)
    }

    func testFallbackLogLinesCarryCodesOnly() {
        XCTAssertEqual(StreamFallbackReason.deadline.logLine, "voice: stream fallback deadline")
        XCTAssertEqual(StreamFallbackReason.http(401).logLine, "voice: stream fallback http-401")
        XCTAssertEqual(StreamFallbackReason.cut.code, "cut")
    }
}

final class StreamQualityMetricsTests: XCTestCase {
    func testStreamFirstAudioMedianAndFallbacks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics = QualityMetrics(now: start, calendar: Calendar(identifier: .gregorian))
        metrics.streamFirstAudio(seconds: 0.3, at: start)
        metrics.streamFirstAudio(seconds: 0.5, at: start)
        metrics.streamFirstAudio(seconds: 0.4, at: start)
        metrics.streamFallback(at: start)
        XCTAssertEqual(metrics.medianStreamFirstAudioToday ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(metrics.lastStreamFirstAudio ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(metrics.today.streamFallbacks, 1)
        XCTAssertEqual(metrics.sinceLaunch.streamFallbacks, 1)
    }

    func testRollsOverAtMidnight() {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics = QualityMetrics(now: start, calendar: calendar)
        metrics.streamFirstAudio(seconds: 0.3, at: start)
        metrics.streamFallback(at: start)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
        metrics.streamFallback(at: tomorrow)
        XCTAssertNil(metrics.medianStreamFirstAudioToday)
        XCTAssertEqual(metrics.today.streamFallbacks, 1)
        XCTAssertEqual(metrics.sinceLaunch.streamFallbacks, 2)
    }

    func testStreamVoiceInTheTurnLine() {
        let stages = TurnStages(firstTextToFirstAudio: 0.31, voice: .stream)
        XCTAssertTrue(stages.logLine.hasSuffix("first text→first audio 310 ms (stream)"))
    }
}
