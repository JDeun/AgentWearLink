import XCTest
@testable import AgentWearLinkCore

final class SSEParserTests: XCTestCase {
    func testParsesEventAcrossChunks() throws {
        var parser = SSEParser()

        XCTAssertTrue(try parser.append(Data("event: delta\ndata: hel".utf8)).isEmpty)
        let events = try parser.append(Data("lo\n\n".utf8))

        XCTAssertEqual(
            events,
            [ServerSentEvent(event: "delta", data: "hello")]
        )
    }

    func testJoinsMultipleDataLines() throws {
        var parser = SSEParser()
        let events = try parser.append(Data("data: first\ndata: second\n\n".utf8))

        XCTAssertEqual(events.first?.data, "first\nsecond")
    }

    func testIgnoresCommentsAndUnknownFields() throws {
        var parser = SSEParser()
        let events = try parser.append(
            Data(": keepalive\nunknown: x\ndata: ok\n\n".utf8)
        )

        XCTAssertEqual(events, [ServerSentEvent(data: "ok")])
    }

    func testPersistsLastEventIDAcrossEvents() throws {
        var parser = SSEParser()
        let events = try parser.append(
            Data("id: 42\ndata: a\n\ndata: b\n\n".utf8)
        )

        XCTAssertEqual(events.map(\.id), ["42", "42"])
    }

    func testAcceptsBareCRLineEndings() throws {
        var parser = SSEParser()
        let events = try parser.append(Data("event: delta\rdata: hello\r\r".utf8))

        XCTAssertEqual(
            events,
            [ServerSentEvent(event: "delta", data: "hello")]
        )
    }

    func testCRLFSplitAcrossChunksDoesNotCreateExtraBlankLine() throws {
        var parser = SSEParser()

        XCTAssertTrue(
            try parser.append(Data("data: one\r".utf8)).isEmpty
        )
        let events = try parser.append(Data("\n\r\ndata: two\n\n".utf8))

        XCTAssertEqual(
            events,
            [
                ServerSentEvent(data: "one"),
                ServerSentEvent(data: "two")
            ]
        )
    }

    func testMultibyteUTF8MaySpanNetworkChunks() throws {
        var parser = SSEParser()
        let bytes = Array("data: 안녕\n\n".utf8)
        let split = bytes.count - 4

        XCTAssertTrue(try parser.append(Data(bytes[..<split])).isEmpty)
        let events = try parser.append(Data(bytes[split...]))

        XCTAssertEqual(events, [ServerSentEvent(data: "안녕")])
    }

    func testLeadingUTF8BOMIsIgnored() throws {
        var parser = SSEParser()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("data: hello\n\n".utf8))

        let events = try parser.append(data)

        XCTAssertEqual(events, [ServerSentEvent(data: "hello")])
    }

    func testInvalidUTF8UsesReplacementDecodingInsteadOfDroppingLine() throws {
        var parser = SSEParser()
        var data = Data("data: ".utf8)
        data.append(0xFF)
        data.append(Data("\n\n".utf8))

        let events = try parser.append(data)

        XCTAssertEqual(events, [ServerSentEvent(data: "\u{FFFD}")])
    }

    func testIncompleteEventIsNotDispatchedWithoutBlankLine() throws {
        var parser = SSEParser()

        let events = try parser.append(Data("data: partial".utf8))

        XCTAssertTrue(events.isEmpty)
    }

    func testAcceptsRetryContainingOnlyASCIIDigits() throws {
        var parser = SSEParser()

        let events = try parser.append(Data("retry: 1000\ndata: ok\n\n".utf8))

        XCTAssertEqual(events, [ServerSentEvent(data: "ok", retryMilliseconds: 1000)])
    }

    func testIgnoresInvalidRetryFields() throws {
        let invalidValues = [
            "-1",
            "+1",
            "1.5",
            "abc",
            "",
            "１２３",
            String(repeating: "9", count: 128)
        ]

        for value in invalidValues {
            var parser = SSEParser()
            let events = try parser.append(
                Data("retry: \(value)\ndata: ok\n\n".utf8)
            )

            XCTAssertEqual(
                events,
                [ServerSentEvent(data: "ok")],
                "Expected retry value '\(value)' to be ignored"
            )
        }
    }
    func testRetryOnlyBlockUpdatesStreamStateWithoutDispatchingEvent() throws {
        var parser = SSEParser()

        let events = try parser.append(Data("retry: 1000\n\n".utf8))

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(parser.latestRetryMilliseconds, 1000)
    }

    func testRetryWithDataUpdatesBothEventMetadataAndStreamState() throws {
        var parser = SSEParser()

        let events = try parser.append(Data("retry: 1500\ndata: ok\n\n".utf8))

        XCTAssertEqual(events, [ServerSentEvent(data: "ok", retryMilliseconds: 1500)])
        XCTAssertEqual(parser.latestRetryMilliseconds, 1500)
    }

    func testLatestValidRetryWinsAcrossBlocks() throws {
        var parser = SSEParser()

        XCTAssertTrue(try parser.append(Data("retry: 1000\n\n".utf8)).isEmpty)
        XCTAssertTrue(try parser.append(Data("retry: 2500\n\n".utf8)).isEmpty)

        XCTAssertEqual(parser.latestRetryMilliseconds, 2500)
    }

    func testInvalidRetryDoesNotOverwriteLatestValidRetry() throws {
        var parser = SSEParser()

        _ = try parser.append(Data("retry: 1000\n\n".utf8))
        _ = try parser.append(Data("retry: -1\n\n".utf8))

        XCTAssertEqual(parser.latestRetryMilliseconds, 1000)
    }

    func testRetryFieldAtEOFAppliesWithoutManufacturingEvent() throws {
        var parser = SSEParser()

        XCTAssertTrue(try parser.append(Data("retry: 3000".utf8)).isEmpty)
        let events = try parser.finish()

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(parser.latestRetryMilliseconds, 3000)
    }

}
