import AppKit

/// 서식 없는 일반 텍스트만 주고받는 텍스트 뷰. 창이 없어도(테스트) 쓸 수 있게 undo 관리자를 직접 가진다.
final class PlainTextView: NSTextView {
    private let ownUndoManager = UndoManager()

    override var undoManager: UndoManager? { ownUndoManager }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

/// 인식 결과를 보여 주는 텍스트 영역. 스트리밍으로 텍스트를 받고, 재인식 한 번을 undo 한 단계로 묶고,
/// 노랑(헷갈리는 글자)·초록(고친 곳) 표시를 화면 전용 임시 속성으로 칠한다.
@MainActor final class RecognizedTextController: NSObject, @MainActor NSTextStorageDelegate {
    let textView: PlainTextView
    var onUserEdit: ((String) -> Void)?
    private(set) var confusionMarks: [NSRange] = []
    private(set) var revisionMarks: [NSRange] = []

    /// 스트리밍 갱신이나 undo 재생 중이면 true. 이때의 텍스트 변경은 사용자 편집으로 보지 않는다.
    private var isReplacingProgrammatically = false
    /// 사용자 편집으로 표시 범위를 고쳤고, 아직 다시 칠하지 않았으면 true.
    private var hasPendingUserEdit = false
    private var savedText = ""

    var string: String { textView.string }

    var isEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    override init() {
        textView = PlainTextView(usingTextLayoutManager: false)
        super.init()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)), name: NSText.didChangeNotification, object: textView)
    }

    func beginReplacement() {
        savedText = string
        textView.breakUndoCoalescing()
    }

    func setStreamingText(_ text: String) {
        replaceAll(with: text)
    }

    func endReplacement() {
        let previous = savedText
        savedText = ""
        guard !previous.isEmpty, previous != string else { return }
        registerSwap(restoring: previous)
    }

    func setMarks(confusion: [NSRange], revision: [NSRange]) {
        confusionMarks = confusion
        revisionMarks = revision
        paintMarks()
    }

    func copyAll(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isReplacingProgrammatically else { return }
        confusionMarks = MarkRanges.adjust(confusionMarks, editedRange: editedRange, changeInLength: delta)
        revisionMarks = MarkRanges.adjust(revisionMarks, editedRange: editedRange, changeInLength: delta)
        hasPendingUserEdit = true
    }

    /// 레이아웃 관리자는 이 대리자 호출이 끝난 뒤에야 편집을 반영하며 임시 속성을 `changeInLength`만큼 민다.
    /// 그래서 다시 칠하기는 편집이 모두 끝난 뒤(`didChangeText`)에 한다.
    @objc private func textDidChange(_ notification: Notification) {
        guard hasPendingUserEdit else { return }
        hasPendingUserEdit = false
        paintMarks()
        onUserEdit?(string)
    }

    // MARK: - Private

    /// 텍스트를 통째로 바꾸고 커서를 끝으로 옮긴다. undo를 등록하지 않는다.
    private func replaceAll(with text: String) {
        isReplacingProgrammatically = true
        defer { isReplacingProgrammatically = false }
        textView.string = text
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
    }

    /// 지금 텍스트와 `old`를 맞바꾸는 undo 한 단계를 등록한다. 실행되면 반대 방향을 다시 등록해 redo가 된다.
    private func registerSwap(restoring old: String) {
        guard let undoManager = textView.undoManager else { return }
        let current = string
        undoManager.registerUndo(withTarget: self) { target in
            target.textView.breakUndoCoalescing()
            target.replaceAll(with: old)
            target.confusionMarks = []
            target.revisionMarks = []
            target.paintMarks()
            target.registerSwap(restoring: current)
        }
    }

    private func paintMarks() {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (string as NSString).length
        let full = NSRange(location: 0, length: length)
        for key: NSAttributedString.Key in [.backgroundColor, .underlineStyle, .underlineColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: full)
        }
        paint(confusionMarks, background: NSColor.systemYellow.withAlphaComponent(0.35), underline: .systemOrange, in: full)
        paint(revisionMarks, background: NSColor.systemGreen.withAlphaComponent(0.25), underline: .systemGreen, in: full)
    }

    private func paint(_ ranges: [NSRange], background: NSColor, underline: NSColor, in full: NSRange) {
        let attributes: [NSAttributedString.Key: Any] = [
            .backgroundColor: background,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: underline,
        ]
        for range in ranges {
            let clamped = NSIntersectionRange(range, full)
            guard clamped.length > 0 else { continue }
            textView.layoutManager?.addTemporaryAttributes(attributes, forCharacterRange: clamped)
        }
    }
}
