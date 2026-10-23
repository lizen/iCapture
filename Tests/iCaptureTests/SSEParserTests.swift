import XCTest

final class SSEParserTests: XCTestCase {
    func testParsesEventAndData() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: "event: content_block_delta"))
        XCTAssertNil(p.feed(line: #"data: {"a":1}"#))
        XCTAssertEqual(p.feed(line: ""), SSEEvent(event: "content_block_delta", data: #"{"a":1}"#))
    }

    func testIgnoresComments() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: ": ping"))
        XCTAssertNil(p.feed(line: ""))
    }

    func testJoinsMultipleDataLinesWithNewline() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: "data: one"))
        XCTAssertNil(p.feed(line: "data: two"))
        XCTAssertEqual(p.feed(line: ""), SSEEvent(event: nil, data: "one\ntwo"))
    }

    func testResetsStateBetweenEvents() {
        var p = SSEParser()
        _ = p.feed(line: "event: a")
        _ = p.feed(line: "data: 1")
        _ = p.feed(line: "")
        _ = p.feed(line: "data: 2")
        XCTAssertEqual(p.feed(line: ""), SSEEvent(event: nil, data: "2"))
    }
}
