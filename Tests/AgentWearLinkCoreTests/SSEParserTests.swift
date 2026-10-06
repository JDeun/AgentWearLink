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
}
