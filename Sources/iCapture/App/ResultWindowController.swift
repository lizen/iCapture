import AppKit
import Combine
import SwiftUI

/// State shown by the result window. Forwards changes from a running session so the view redraws.
@MainActor
final class ResultModel: ObservableObject {
    /// Local model (auto) comes first. It's the default engine and costs nothing.
    static let baseChoices: [EngineChoice] = [.localAuto, .claude(.sonnet), .claude(.haiku)]

    @Published var image: NSImage?
    /// nil when reopened from history (no running session).
    @Published private(set) var session: RecognitionSession?
    /// Engine name shown in the status line when history is opened without a session.
    @Published var historyEngineName = ""
    @Published var engineOptions: [EngineChoice] = ResultModel.baseChoices
    /// Used only for "Recognize Again". Does not change `settings.engine`.
    @Published var selectedEngine: EngineChoice = .localAuto
    /// After "Skip Check", `.verifying` lasts until OCR finishes, so the button is disabled separately.
    @Published var skipPressed = false
    @Published var canRecognizeAgain = false

    var onRecognizeAgain: ((EngineChoice) -> Void)?
    var onCancel: (() -> Void)?
    var onSkipVerification: (() -> Void)?
    var onCopyAll: (() -> Void)?

    private var sessionChange: AnyCancellable?

    var isRunning: Bool { session?.isRunning ?? false }

    func setSession(_ session: RecognitionSession?) {
        self.session = session
        skipPressed = false
        sessionChange = session?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Local (auto) + two Claude models + the local server's models. If the selected engine isn't listed (e.g. the server is down), it's appended so the Picker isn't empty.
    func setLocalLLMModels(_ ids: [String]) {
        var options = Self.baseChoices + ids.map { EngineChoice.localLLM(modelID: $0) }
        if !options.contains(selectedEngine) { options.append(selectedEngine) }
        engineOptions = options
    }

    func select(_ choice: EngineChoice) {
        selectedEngine = choice
        if !engineOptions.contains(choice) { engineOptions.append(choice) }
    }
}

/// One result window, reused until the app quits. The text area (`RecognizedTextController`) lives as long as the window.
@MainActor
final class ResultWindowController: NSObject, NSWindowDelegate {
    let textController = RecognizedTextController()
    let model = ResultModel()

    var onClose: (() -> Void)?
    var onBecameKey: (() -> Void)?

    private var window: NSWindow?
    private var escMonitor: Any?

    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    func show() {
        let window = window ?? makeWindow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Keep the window in front even if activation is delayed because another app is frontmost.
        window.orderFrontRegardless()
        focusTextView(in: window)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey?()
    }

    // MARK: - Private

    /// On first creation the hosting view may not be laid out yet, so the text view may not be in the window.
    /// Then it can't become first responder and ⌘A/⌘C don't work until a click, so lay out first and retry on the next turn if still detached.
    private func focusTextView(in window: NSWindow) {
        window.layoutIfNeeded()
        let textView = textController.textView
        if textView.window === window {
            window.makeFirstResponder(textView)
            return
        }
        DispatchQueue.main.async { [weak window, weak textView] in
            guard let window, let textView, textView.window === window else { return }
            window.makeFirstResponder(textView)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iCapture"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        let hosting = NSHostingView(rootView: ResultView(model: model, text: textController))
        // Follow only the minimum size so SwiftUI's ideal size doesn't shrink or grow the window.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setContentSize(NSSize(width: 960, height: 560))
        window.center()

        installEscMonitor(for: window)
        self.window = window
        return window
    }

    /// When the text view is first responder, esc is swallowed as `cancelOperation:` (completion).
    /// So while running, intercept esc in this window first and use it as cancel.
    private func installEscMonitor(for window: NSWindow) {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard event.keyCode == 53 else { return event }
            let eventWindow = event.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window, eventWindow === window, self.model.isRunning else { return false }
                self.model.onCancel?()
                return true
            }
            return handled ? nil : event
        }
    }
}
