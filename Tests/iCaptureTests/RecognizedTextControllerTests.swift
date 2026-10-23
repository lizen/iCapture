import AppKit
import XCTest
@testable import iCapture

@MainActor
final class RecognizedTextControllerTests: XCTestCase {
    func testUndoRestoresPreviousRecognition() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("u.1evel"); c.endReplacement()
        c.beginReplacement(); c.setStreamingText("u.le"); c.setStreamingText("u.level"); c.endReplacement()
        c.textView.undoManager!.undo(); XCTAssertEqual(c.string, "u.1evel")
        c.textView.undoManager!.redo(); XCTAssertEqual(c.string, "u.level")
    }

    func testFirstRecognitionIsNotUndoable() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("SELECT 1"); c.endReplacement()
        XCTAssertEqual(c.string, "SELECT 1")
        XCTAssertFalse(c.textView.undoManager!.canUndo)
    }

    func testCopyAllWritesPlainStringOnly() {
        let pb = NSPasteboard(name: .init("icapture.tests.\(UUID())"))
        defer { pb.releaseGlobally() }
        let c = RecognizedTextController(); c.beginReplacement(); c.setStreamingText("SELECT 1"); c.endReplacement()
        c.setMarks(confusion: [NSRange(location: 7, length: 1)], revision: [])
        c.copyAll(to: pb)
        // `pb.types`에는 시스템이 붙이는 옛 별칭(NSStringPboardType)이 늘 함께 나오므로 항목의 형식을 본다.
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertEqual(pb.pasteboardItems?.first?.types, [.string])
        XCTAssertEqual(pb.string(forType: .string), "SELECT 1")
    }

    func testWritableTypesArePlain() {
        XCTAssertEqual(RecognizedTextController().textView.writablePasteboardTypes, [.string])
    }

    func testUserEditRemovesTouchedMark() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("WHERE u.level = 1"); c.endReplacement()
        c.setMarks(confusion: [NSRange(location: 8, length: 1)], revision: [])
        var edits: [String] = []
        c.onUserEdit = { edits.append($0) }

        userReplace(c, NSRange(location: 8, length: 1), with: "L")

        XCTAssertEqual(c.string, "WHERE u.Level = 1")
        XCTAssertEqual(c.confusionMarks, [])
        XCTAssertEqual(edits, ["WHERE u.Level = 1"])
    }

    func testUserEditShiftsLaterMarks() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("WHERE u.level = 1"); c.endReplacement()
        c.setMarks(confusion: [NSRange(location: 8, length: 1)], revision: [NSRange(location: 16, length: 1)])

        userReplace(c, NSRange(location: 0, length: 0), with: "  ")

        XCTAssertEqual(c.confusionMarks, [NSRange(location: 10, length: 1)])
        XCTAssertEqual(c.revisionMarks, [NSRange(location: 18, length: 1)])
        let lm = c.textView.layoutManager!
        XCTAssertNotNil(lm.temporaryAttributes(atCharacterIndex: 10, effectiveRange: nil)[.backgroundColor])
        XCTAssertNil(lm.temporaryAttributes(atCharacterIndex: 8, effectiveRange: nil)[.backgroundColor])
        XCTAssertNil(lm.temporaryAttributes(atCharacterIndex: 12, effectiveRange: nil)[.backgroundColor])
    }

    func testStreamingDoesNotCallOnUserEdit() {
        let c = RecognizedTextController()
        var count = 0
        c.onUserEdit = { _ in count += 1 }
        c.beginReplacement(); c.setStreamingText("u."); c.setStreamingText("u.level"); c.endReplacement()
        XCTAssertEqual(count, 0)
    }

    func testMarksArePaintedAsTemporaryAttributesOnly() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("SELECT 1"); c.endReplacement()
        c.setMarks(confusion: [NSRange(location: 7, length: 1)], revision: [NSRange(location: 0, length: 6)])
        let lm = c.textView.layoutManager!
        let yellow = lm.temporaryAttributes(atCharacterIndex: 7, effectiveRange: nil)
        XCTAssertEqual(yellow[.backgroundColor] as? NSColor, NSColor.systemYellow.withAlphaComponent(0.35))
        XCTAssertEqual(yellow[.underlineColor] as? NSColor, NSColor.systemOrange)
        let green = lm.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)
        XCTAssertEqual(green[.backgroundColor] as? NSColor, NSColor.systemGreen.withAlphaComponent(0.25))
        XCTAssertNil(lm.temporaryAttributes(atCharacterIndex: 6, effectiveRange: nil)[.backgroundColor])
        XCTAssertNil(c.textView.textStorage!.attribute(.backgroundColor, at: 7, effectiveRange: nil))
    }

    func testUndoClearsMarks() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("u.1evel"); c.endReplacement()
        c.beginReplacement(); c.setStreamingText("u.level"); c.endReplacement()
        c.setMarks(confusion: [NSRange(location: 2, length: 1)], revision: [NSRange(location: 2, length: 1)])
        c.textView.undoManager!.undo()
        XCTAssertEqual(c.confusionMarks, []); XCTAssertEqual(c.revisionMarks, [])
    }

    /// 실제 타이핑과 같은 경로로 사용자 편집을 흉내 낸다.
    private func userReplace(_ c: RecognizedTextController, _ range: NSRange, with text: String) {
        let tv = c.textView
        XCTAssertTrue(tv.shouldChangeText(in: range, replacementString: text))
        tv.textStorage!.replaceCharacters(in: range, with: text)
        tv.didChangeText()
    }
}
