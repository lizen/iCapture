import AppKit
import Combine

/// A text view that only exchanges plain text. Owns its undo manager so it works without a window (tests).
final class PlainTextView: NSTextView {
    private let ownUndoManager = UndoManager()
    /// While true (during re-recognition streaming), undo/redo are blocked.
    var isUndoBlocked = false

    override var undoManager: UndoManager? { ownUndoManager }
    // Leave the writable types alone. With `isRichText = false` the default is already plain text only (NSStringPboardType);
    // overriding it with `.string` makes `writeSelection(to:type:)` reject the type, so ⌘C copies nothing.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // Left alone, ⌘Z/⌘⇧Z (`undo:`/`redo:`) in a window travel up the responder chain to NSWindow's undo manager.
    // Catch them here and send them to this view's undo manager.
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

/// Text area showing the recognition result. Receives streamed text, groups one re-recognition into a single undo step,
/// and paints yellow (look-alike) and green (revised) marks as display-only temporary attributes.
/// Publishes mark changes so the result window's "needs review N" follows user edits.
@MainActor final class RecognizedTextController: NSObject, ObservableObject, @MainActor NSTextStorageDelegate {
    let textView: PlainTextView
    /// Called when the user edits the text and when a re-recognition undo/redo changes it. Not called for streaming updates.
    var onUserEdit: ((String) -> Void)?
    @Published private(set) var confusionMarks: [NSRange] = []
    @Published private(set) var revisionMarks: [NSRange] = []

    /// true during streaming updates or undo replay. Text changes then aren't treated as user edits.
    private var isReplacingProgrammatically = false
    /// true when a user edit adjusted the mark ranges and they haven't been repainted yet.
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

    /// Starts a re-recognition. Saves the current text and blocks undo/redo until `endReplacement()`.
    /// Contract: once started, every terminal path (done, cancelled, failed) must call `endReplacement()`.
    func beginReplacement() {
        guard !isInReplacement else { return }
        isInReplacement = true
        savedText = string
        textView.isUndoBlocked = true
        textView.breakUndoCoalescing()
    }

    /// Replaces the whole text and moves the cursor to the end.
    func setStreamingText(_ text: String) {
        replaceAll(with: text)
        // If this change won't be replaced by a single swap step, clear the history so leftover typing undo can't apply to the new text.
        if !isInReplacement || savedText.isEmpty {
            textView.undoManager?.removeAllActions()
        }
    }

    /// Ends a re-recognition. If there's saved text that differs from the current text, registers one undo step that swaps them.
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

    /// The edited range is taken in `willProcessEditing`. By `didProcessEditing`, attribute fixing (fixAttributes) has
    /// widened it to the end of the paragraph, so typing one character would clear every later mark in that paragraph.
    func textStorage(
        _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isReplacingProgrammatically else { return }
        // Assign only on change. Assigning unconditionally would redraw the result window on every keystroke unrelated to marks.
        let confusion = MarkRanges.adjust(confusionMarks, editedRange: editedRange, changeInLength: delta)
        if confusion != confusionMarks { confusionMarks = confusion }
        let revision = MarkRanges.adjust(revisionMarks, editedRange: editedRange, changeInLength: delta)
        if revision != revisionMarks { revisionMarks = revision }
        hasPendingUserEdit = true
    }

    /// The layout manager applies the edit only after the delegate call returns, shifting temporary attributes by `changeInLength`.
    /// So repainting happens after the whole edit is done (`didChangeText`).
    @objc private func textDidChange(_ notification: Notification) {
        guard hasPendingUserEdit else { return }
        hasPendingUserEdit = false
        paintMarks()
        onUserEdit?(string)
    }

    // MARK: - Private

    /// Replaces the whole text and moves the cursor to the end. Registers no undo.
    private func replaceAll(with text: String) {
        isReplacingProgrammatically = true
        defer { isReplacingProgrammatically = false }
        hasPendingUserEdit = false
        textView.string = text
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
    }

    /// Registers one undo step that swaps the current text with `old`. When run, it registers the opposite direction, which becomes redo.
    /// When run, it replaces the text, clears both mark sets, and reports via `onUserEdit`.
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
