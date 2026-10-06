import XCTest
@testable import AgentWearLinkCore

final class SSEParserTests: XCTestCase {
    func testParsesEventAcrossChunks() {
        var parser = SSEParser()

        XCTAssertTrue(parser.append(Data("event: delta\ndata: hel".utf8)).isEmpty)
        let events = parser.append(Data("lo\n\n".utf8))

        XCTAssertEqual(
            events,
            [ServerSentEvent(event: "delta", data: "hello")]
        )
    }

    func testJoinsMultipleDataLines() {
        var parser = SSEParser()
        let events = parser.append(Data("data: first\ndata: second\n\n".utf8))

        XCTAssertEqual(events.first?.data, "first\nsecond")
    }

    func testIgnoresCommentsAndUnknownFields() {
        var parser = SSEParser()
        let events = parser.append(
            Data(": keepalive\nunknown: x\ndata: ok\n\n".utf8)
        )

        XCTAssertEqual(events, [ServerSentEvent(data: "ok")])
    }

    func testPersistsLastEventIDAcrossEvents() {
        var parser = SSEParser()
        let events = parser.append(
            Data("id: 42\ndata: a\n\ndata: b\n\n".utf8)
        )

        XCTAssertEqual(events.map(\.id), ["42", "42"])
    }

    func testAcceptsBareCRLineEndings() {
        var parser = SSEParser()
        let events = parser.append(Data("event: delta\rdata: hello\r\r".utf8))

        XCTAssertEqual(
            events,
            [ServerSentEvent(event: "delta", data: "hello")]
        )
    }

    func testCRLFSplitAcrossChunksDoesNotCreateExtraBlankLine() {
        var parser = SSEParser()

        XCTAssertTrue(
            parser.append(Data("data: one\r".utf8)).isEmpty
        )
        let events = parser.append(Data("\n\r\ndata: two\n\n".utf8))

        XCTAssertEqual(
            events,
            [
                ServerSentEvent(data: "one"),
                ServerSentEvent(data: "two")
            ]
        )
    }

    func testMultibyteUTF8MaySpanNetworkChunks() {
        var parser = SSEParser()
        let bytes = Array("data: 안녕\n\n".utf8)
        let split = bytes.count - 4

        XCTAssertTrue(parser.append(Data(bytes[..<split])).isEmpty)
        let events = parser.append(Data(bytes[split...]))

        XCTAssertEqual(events, [ServerSentEvent(data: "안녕")])
    }

    func testLeadingUTF8BOMIsIgnored() {
        var parser = SSEParser()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("data: hello\n\n".utf8))

        let events = parser.append(data)

        XCTAssertEqual(events, [ServerSentEvent(data: "hello")])
    }

    func testInvalidUTF8UsesReplacementDecodingInsteadOfDroppingLine() {
        var parser = SSEParser()
        var data = Data("data: ".utf8)
        data.append(0xFF)
        data.append(Data("\n\n".utf8))

        let events = parser.append(data)

        XCTAssertEqual(events, [ServerSentEvent(data: "\u{FFFD}")])
    }

    func testIncompleteEventIsNotDispatchedWithoutBlankLine() {
        var parser = SSEParser()

        let events = parser.append(Data("data: partial".utf8))

        XCTAssertTrue(events.isEmpty)
    }
}
