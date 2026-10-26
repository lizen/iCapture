import AppKit
import Combine
import XCTest

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

    /// 드래그로 고른 뒤 ⌘C(`copy:`)가 쓰는 경로. 고른 부분만, 서식 없는 텍스트로 들어가야 한다.
    func testSelectionCopyWritesSelectedPlainText() {
        let pb = NSPasteboard(name: .init("icapture.tests.\(UUID())"))
        defer { pb.releaseGlobally() }
        let c = RecognizedTextController(); c.beginReplacement(); c.setStreamingText("SELECT name FROM users"); c.endReplacement()
        c.setMarks(confusion: [NSRange(location: 7, length: 1)], revision: [])
        c.textView.setSelectedRange(NSRange(location: 7, length: 4))
        pb.clearContents()

        XCTAssertTrue(c.textView.writeSelection(to: pb, types: c.textView.writablePasteboardTypes))
        XCTAssertEqual(pb.string(forType: .string), "name")
        XCTAssertNil(pb.data(forType: .rtf))
        XCTAssertNil(pb.data(forType: .rtfd))
    }

    /// ⌘V(`paste:`)가 쓰는 경로. 다른 앱에서 복사한 서식 있는 글도 글자만 들어와야 한다.
    func testPasteReadsPlainText() {
        let pb = NSPasteboard(name: .init("icapture.tests.\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([NSAttributedString(string: "users", attributes: [.foregroundColor: NSColor.red])])
        let c = RecognizedTextController(); c.beginReplacement(); c.setStreamingText("FROM "); c.endReplacement()
        c.isEditable = true
        c.textView.setSelectedRange(NSRange(location: 5, length: 0))

        XCTAssertTrue(c.textView.readSelection(from: pb))
        XCTAssertEqual(c.string, "FROM users")
        let pastedColor = c.textView.textStorage?.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(pastedColor, NSColor.red)
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

    /// 결과 창의 "확인 필요 N곳"이 사용자 편집을 따라가도록 표시가 바뀌면 알린다. 표시와 상관없는 타이핑은 알리지 않는다.
    func testMarkChangesArePublished() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("WHERE u.level = 1"); c.endReplacement()
        var notifications = 0
        let subscription = c.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        c.setMarks(confusion: [NSRange(location: 8, length: 1)], revision: [])
        XCTAssertGreaterThan(notifications, 0)

        notifications = 0
        userReplace(c, NSRange(location: 17, length: 0), with: "0")
        XCTAssertEqual(notifications, 0)

        userReplace(c, NSRange(location: 8, length: 1), with: "L")
        XCTAssertEqual(c.confusionMarks.count, 0)
        XCTAssertGreaterThan(notifications, 0)
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

    // MARK: - 실제 입력 경로(타이핑·IME)

    private let paragraphText = "ab cdefgh ijk\nline2 x"
    private let paragraphMarks = [NSRange(location: 5, length: 1), NSRange(location: 11, length: 1), NSRange(location: 20, length: 1)]
    private let shiftedMarks = [NSRange(location: 6, length: 1), NSRange(location: 12, length: 1), NSRange(location: 21, length: 1)]
    private let noReplacement = NSRange(location: NSNotFound, length: 0)

    func testTypingKeepsMarksLaterInSameParagraph() {
        let c = recognized(paragraphText)
        c.setMarks(confusion: paragraphMarks, revision: [])
        var edits: [String] = []
        c.onUserEdit = { edits.append($0) }
        c.textView.setSelectedRange(NSRange(location: 3, length: 0))
        c.textView.insertText("k", replacementRange: noReplacement)
        XCTAssertEqual(c.string, "ab kcdefgh ijk\nline2 x")
        XCTAssertEqual(c.confusionMarks, shiftedMarks)
        XCTAssertEqual(edits, ["ab kcdefgh ijk\nline2 x"])
        XCTAssertNotNil(c.textView.layoutManager!.temporaryAttributes(atCharacterIndex: 6, effectiveRange: nil)[.backgroundColor])
    }

    func testIMECommitKeepsMarksLaterInSameParagraph() {
        let c = recognized(paragraphText)
        c.setMarks(confusion: paragraphMarks, revision: [])
        let tv = c.textView
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        tv.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0), replacementRange: noReplacement)
        tv.insertText("각", replacementRange: noReplacement)
        XCTAssertEqual(c.string, "ab 각cdefgh ijk\nline2 x")
        XCTAssertEqual(c.confusionMarks, shiftedMarks)
    }

    // MARK: - 창 안의 undo:/redo:

    func testWindowUndoRedoActionsReachTextViewUndoManager() {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText("u.1evel"); c.endReplacement()
        c.beginReplacement(); c.setStreamingText("u.level"); c.endReplacement()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        c.textView.frame = window.contentView!.bounds
        window.contentView!.addSubview(c.textView)
        XCTAssertTrue(window.makeFirstResponder(c.textView))
        let responder = window.firstResponder!

        XCTAssertTrue(c.textView.validateMenuItem(NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "")))
        XCTAssertTrue(responder.tryToPerform(Selector(("undo:")), with: nil))
        XCTAssertEqual(c.string, "u.1evel")
        XCTAssertTrue(c.textView.validateMenuItem(NSMenuItem(title: "", action: Selector(("redo:")), keyEquivalent: "")))
        XCTAssertTrue(responder.tryToPerform(Selector(("redo:")), with: nil))
        XCTAssertEqual(c.string, "u.level")
    }

    // MARK: - 남은 타이핑 undo

    func testRerecognitionAfterDeletingEverythingClearsHistory() {
        let c = recognized("hello")
        c.textView.setSelectedRange(NSRange(location: 0, length: 5))
        c.textView.insertText("", replacementRange: noReplacement)
        XCTAssertEqual(c.string, "")
        c.beginReplacement(); c.setStreamingText("world wide"); c.endReplacement()
        XCTAssertFalse(c.textView.undoManager!.canUndo)
        XCTAssertEqual(c.string, "world wide")
    }

    func testStreamingOutsideReplacementClearsHistory() {
        let c = recognized("hello")
        c.textView.setSelectedRange(NSRange(location: 5, length: 0))
        c.textView.insertText("!!", replacementRange: noReplacement)
        XCTAssertTrue(c.textView.undoManager!.canUndo)
        c.setStreamingText("hi")
        XCTAssertFalse(c.textView.undoManager!.canUndo)
    }

    func testUndoIsBlockedWhileStreaming() {
        let c = recognized("hello world")
        c.textView.setSelectedRange(NSRange(location: 11, length: 0))
        c.textView.insertText("!!", replacementRange: noReplacement)
        c.beginReplacement(); c.setStreamingText("hi")
        XCTAssertFalse(c.textView.validateMenuItem(NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "")))
        c.textView.undo(nil)
        XCTAssertEqual(c.string, "hi")
        c.endReplacement()
        XCTAssertTrue(c.textView.validateMenuItem(NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "")))
    }

    // MARK: - 재인식 undo/redo 알림, 연속 begin

    func testRecognitionUndoRedoCallsOnUserEdit() {
        let c = recognized("u.1evel")
        c.beginReplacement(); c.setStreamingText("u.level"); c.endReplacement()
        var edits: [String] = []
        c.onUserEdit = { edits.append($0) }
        c.textView.undoManager!.undo()
        c.textView.undoManager!.redo()
        XCTAssertEqual(edits, ["u.1evel", "u.level"])
    }

    func testSecondBeginKeepsSavedText() {
        let c = recognized("first")
        c.beginReplacement(); c.setStreamingText("se")
        c.beginReplacement(); c.setStreamingText("second"); c.endReplacement()
        c.textView.undoManager!.undo()
        XCTAssertEqual(c.string, "first")
    }

    private func recognized(_ text: String) -> RecognizedTextController {
        let c = RecognizedTextController()
        c.beginReplacement(); c.setStreamingText(text); c.endReplacement()
        return c
    }

    /// 실제 타이핑과 같은 경로로 사용자 편집을 흉내 낸다.
    private func userReplace(_ c: RecognizedTextController, _ range: NSRange, with text: String) {
        let tv = c.textView
        XCTAssertTrue(tv.shouldChangeText(in: range, replacementString: text))
        tv.textStorage!.replaceCharacters(in: range, with: text)
        tv.didChangeText()
    }
}
