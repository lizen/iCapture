import AppKit

/// 서식 없는 일반 텍스트만 주고받는 텍스트 뷰. 창이 없어도(테스트) 쓸 수 있게 undo 관리자를 직접 가진다.
final class PlainTextView: NSTextView {
    private let ownUndoManager = UndoManager()
    /// true인 동안(재인식 스트리밍 중)은 undo/redo를 막는다.
    var isUndoBlocked = false

    override var undoManager: UndoManager? { ownUndoManager }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // 창 안의 ⌘Z/⌘⇧Z(`undo:`/`redo:`)는 그냥 두면 응답자 체인을 따라 NSWindow의 undo 관리자로 간다.
    // 여기서 받아 이 뷰의 undo 관리자로 보낸다.
    @objc func undo(_ sender: Any?) {
        if !isUndoBlocked { ownUndoManager.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if !isUndoBlocked { ownUndoManager.redo() }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        undoValidation(for: menuItem.action) ?? super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        undoValidation(for: item.action) ?? super.validateUserInterfaceItem(item)
    }

    private func undoValidation(for action: Selector?) -> Bool? {
        switch action {
        case #selector(undo(_:)): !isUndoBlocked && ownUndoManager.canUndo
        case #selector(redo(_:)): !isUndoBlocked && ownUndoManager.canRedo
        default: nil
        }
    }
}

/// 인식 결과를 보여 주는 텍스트 영역. 스트리밍으로 텍스트를 받고, 재인식 한 번을 undo 한 단계로 묶고,
/// 노랑(헷갈리는 글자)·초록(고친 곳) 표시를 화면 전용 임시 속성으로 칠한다.
@MainActor final class RecognizedTextController: NSObject, @MainActor NSTextStorageDelegate {
    let textView: PlainTextView
    /// 사용자가 직접 고쳤을 때, 그리고 재인식 undo/redo로 텍스트가 바뀌었을 때 불린다. 스트리밍 갱신에서는 불리지 않는다.
    var onUserEdit: ((String) -> Void)?
    private(set) var confusionMarks: [NSRange] = []
    private(set) var revisionMarks: [NSRange] = []

    /// 스트리밍 갱신이나 undo 재생 중이면 true. 이때의 텍스트 변경은 사용자 편집으로 보지 않는다.
    private var isReplacingProgrammatically = false
    /// 사용자 편집으로 표시 범위를 고쳤고, 아직 다시 칠하지 않았으면 true.
    private var hasPendingUserEdit = false
    private var isInReplacement = false
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

    /// 재인식을 시작한다. 지금 텍스트를 보관하고, `endReplacement()`까지 undo/redo를 막는다.
    /// 계약: 시작했으면 끝나는 모든 경로(완료·취소·오류)에서 반드시 `endReplacement()`를 불러야 한다.
    func beginReplacement() {
        guard !isInReplacement else { return }
        isInReplacement = true
        savedText = string
        textView.isUndoBlocked = true
        textView.breakUndoCoalescing()
    }

    /// 텍스트를 통째로 바꾸고 커서를 끝으로 옮긴다.
    func setStreamingText(_ text: String) {
        replaceAll(with: text)
        // swap 한 단계로 대체되지 않을 변경이면, 남은 타이핑 undo가 새 텍스트에 엉뚱하게 적용되지 않게 기록을 비운다.
        if !isInReplacement || savedText.isEmpty {
            textView.undoManager?.removeAllActions()
        }
    }

    /// 재인식을 끝낸다. 보관한 텍스트가 있고 지금과 다르면, 둘을 맞바꾸는 undo 한 단계를 등록한다.
    func endReplacement() {
        guard isInReplacement else { return }
        isInReplacement = false
        textView.isUndoBlocked = false
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

    /// 편집 범위는 `willProcessEditing`에서 받는다. `didProcessEditing` 때는 속성 정리(fixAttributes) 때문에
    /// 범위가 문단 끝까지 넓어져 있어서, 타이핑 한 글자에 같은 문단의 뒤쪽 표시가 모두 지워진다.
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isReplacingProgrammatically else { return }
        confusionMarks = MarkRanges.adjust(confusionMarks, editedRange: editedRange, changeInLength: delta)
        revisionMarks = MarkRanges.adjust(revisionMarks, editedRange: editedRange, changeInLength: delta)
        hasPendingUserEdit = true
    }

    /// 레이아웃 관리자는 대리자 호출이 끝난 뒤에야 편집을 반영하며 임시 속성을 `changeInLength`만큼 민다.
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
        hasPendingUserEdit = false
        textView.string = text
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
    }

    /// 지금 텍스트와 `old`를 맞바꾸는 undo 한 단계를 등록한다. 실행되면 반대 방향을 다시 등록해 redo가 된다.
    /// 실행되면 텍스트를 바꾸고 두 표시를 비운 뒤 `onUserEdit`로 알린다.
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
            target.onUserEdit?(target.string)
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
