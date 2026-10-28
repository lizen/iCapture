import XCTest

final class KindTagParserTests: XCTestCase {
    func testTagThenBody() {
        var p = KindTagParser()
        XCTAssertEqual(p.consume("<<KIND:sql>>\nSELECT").body, "SELECT")
    }

    func testTagSplitAcrossChunks() {
        var p = KindTagParser()
        XCTAssertEqual(p.consume("<<KI").body, "")
        let r = p.consume("ND:log>>\njava.lang")
        XCTAssertEqual(r.kind, .log)
        XCTAssertEqual(r.body, "java.lang")
    }

    func testMissingTagFallsBackToOther() {
        var p = KindTagParser()
        let r = p.consume("SELECT 1")
        XCTAssertEqual(r.kind, .other)
        XCTAssertEqual(r.body, "SELECT 1")
    }

    func testStripsCodeFence() {
        let r = KindTagParser.parseComplete("<<KIND:sql>>\n```sql\nSELECT 1\n```")
        XCTAssertEqual(r.kind, .sql)
        XCTAssertEqual(r.body, "SELECT 1")
    }

    func testPreservesIndentationAndKorean() {
        let raw = "<<KIND:sql>>\n-- 회원 조회\nSELECT u.id\n  FROM users u"
        XCTAssertEqual(KindTagParser.parseComplete(raw).body, "-- 회원 조회\nSELECT u.id\n  FROM users u")
    }

    func testUnknownTagValueIsOther() {
        XCTAssertEqual(KindTagParser.parseComplete("<<KIND:yaml>>\na: 1").kind, .other)
        XCTAssertEqual(KindTagParser.parseComplete("<<KIND:yaml>>\na: 1").body, "a: 1")
    }

    func testHoldsUntilNewlineAfterStartedTag() {
        var p = KindTagParser()
        let first = p.consume("<<KIND:sql>>")
        XCTAssertNil(first.kind)
        XCTAssertEqual(first.body, "")
        let second = p.consume("\nSELECT")
        XCTAssertEqual(second.kind, .sql)
        XCTAssertEqual(second.body, "SELECT")
    }

    func testReleasesHeldTextWhenItCannotBeATag() {
        var p = KindTagParser()
        XCTAssertEqual(p.consume("<<").body, "")
        let r = p.consume("not a tag")
        XCTAssertEqual(r.kind, .other)
        XCTAssertEqual(r.body, "<<not a tag")
    }

    func testKindIsReportedOnlyOnce() {
        var p = KindTagParser()
        XCTAssertEqual(p.consume("<<KIND:table>>\n| a |").kind, .table)
        let next = p.consume("\n| 1 |")
        XCTAssertNil(next.kind)
        XCTAssertEqual(next.body, "| a |\n| 1 |")
    }

    func testStreamingUnknownTagIsRemovedAndOther() {
        var p = KindTagParser()
        let r = p.consume("<<KIND:yaml>>\na: 1")
        XCTAssertEqual(r.kind, .other)
        XCTAssertEqual(r.body, "a: 1")
    }

    func testStreamingHidesOpeningFenceButKeepsTrailingFence() {
        var p = KindTagParser()
        XCTAssertEqual(p.consume("<<KIND:sql>>\n```sql\nSELECT 1\n").body, "SELECT 1\n")
        XCTAssertEqual(p.consume("```").body, "SELECT 1\n```")
    }

    func testParseCompleteWithoutTrailingNewlineAfterTag() {
        let r = KindTagParser.parseComplete("<<KIND:log>>")
        XCTAssertEqual(r.kind, .log)
        XCTAssertEqual(r.body, "")
    }

    func testBadges() {
        XCTAssertEqual(TextKind.allCases.map(\.badge), ["SQL", "Log", "Table", "Other"])
    }

    func testPromptConstants() {
        XCTAssertTrue(RecognitionPrompt.system.hasPrefix("You transcribe text from a screenshot exactly as it appears.\n\nOutput format:"))
        XCTAssertTrue(RecognitionPrompt.system.hasSuffix("- If text is cut off at the edge of the image, transcribe only what is visible."))
        XCTAssertEqual(RecognitionPrompt.userInstruction, "Transcribe this screenshot.")
    }
}
