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
}
