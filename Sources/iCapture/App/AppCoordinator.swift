import AppKit
import Combine

/// Wires hotkey -> region selection -> capture -> recognition session -> result window -> history.
@MainActor
final class AppCoordinator: NSObject {
    private let settings: AppSettings
    private let history: HistoryStore
    private let keychain: KeychainStore

    private let hotKeyMonitor = HotKeyMonitor()
    private let overlay = RegionSelectionOverlay()
    private let resultWindow = ResultWindowController()
    private let historyWindow: HistoryWindowController
    private let settingsWindow: SettingsWindowController
    private var statusMenu: StatusMenuController?

    private var session: RecognitionSession?
    private var sessionBindings: Set<AnyCancellable> = []
    /// The history entry shown in the result window and its PNG. "Recognize Again" and edit saves overwrite this entry.
    private var currentEntry: HistoryEntry?
    private var currentPNG: Data?
    private var isCapturing = false
    private var pendingEditSave: Task<Void, Never>?
    private var llmModelsTask: Task<Void, Never>?

    init(settings: AppSettings, history: HistoryStore, keychain: KeychainStore) {
        self.settings = settings
        self.history = history
        self.keychain = keychain
        historyWindow = HistoryWindowController(history: history)
        settingsWindow = SettingsWindowController(settings: settings, keychain: keychain)
        super.init()
        wireResultWindow()
        wireHistoryWindow()
        wireSettingsWindow()
    }

    func start() {
        installMainMenu()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = StatusMenuController(statusItem: statusItem)
        menu.onCapture = { [weak self] in self?.captureRegion() }
        menu.onOpenEntry = { [weak self] entry in self?.reopen(entry) }
        menu.onShowHistory = { [weak self] in self?.showHistory() }
        menu.onShowSettings = { [weak self] in self?.showSettings() }
        menu.setCaptureShortcut(settings.hotKey)
        statusMenu = menu
        refreshRecentEntries()

        applyHotKey(settings.hotKey)
        warmUpVision()
    }

    func captureRegion() {
        guard !isCapturing else { return }
        guard ScreenRecordingPermission.isGranted else {
            showPermissionAlert()
            return
        }

        isCapturing = true
        Task {
            defer { isCapturing = false }
            // Dismissing the selection with esc leaves a running recognition alone. The previous session ends only after a region is chosen.
            guard let selection = await overlay.selectRegion() else { return }
            finishCurrentSession()
            do {
                let image = try await ScreenCapturer().capture(rect: selection.rect, on: selection.screen)
                let png = try ImageEncoder.png(from: image)
                beginCapture(png: png, image: NSImage(cgImage: image, size: selection.rect.size))
            } catch {
                NSLog("iCapture capture failed: %@", String(describing: error))
                showCaptureFailedAlert(error)
            }
        }
    }

    /// Called right before the app quits. Saves any pending edit, cancels a running session so what was received is kept in history
    /// (a cancel with no text keeps the previous result), and commits keys being typed in the settings window.
    func prepareForTermination() {
        finishCurrentSession()
        settingsWindow.commitPending()
    }

    /// Reopens a history entry in the result window without a session. The text is immediately editable.
    func reopen(_ entry: HistoryEntry) {
        finishCurrentSession()
        detachSession()
        // Menu items are copies from the last save. If the same entry is open in the window, use that newer copy.
        let entry = currentEntry?.id == entry.id ? currentEntry ?? entry : entry

        let imageURL = history.imageURL(for: entry.id)
        currentEntry = entry
        currentPNG = try? Data(contentsOf: imageURL)

        let text = resultWindow.textController
        text.setMarks(confusion: [], revision: [])
        // Clear first so no undo step leads back to another capture's text.
        text.setStreamingText("")
        text.beginReplacement()
        text.setStreamingText(entry.text)
        text.endReplacement()
        text.isEditable = true

        let model = resultWindow.model
        model.image = currentPNG.flatMap { NSImage(data: $0) }
        model.historyEngineName = entry.engine.displayName
        model.canRecognizeAgain = currentPNG != nil
        model.select(model.engineOptions.contains(entry.engine) ? entry.engine : settings.engine)
        statusMenu?.iconState = .idle
        showResultWindow()
    }

    /// Runs a new session on the same PNG and overwrites the same history entry. Does not change `settings.engine`.
    func recognizeAgain(with choice: EngineChoice) {
        guard let png = currentPNG, currentEntry != nil else { return }
        finishCurrentSession()
        startSession(png: png, choice: choice)
    }

    /// Keys are read from the Keychain every time. Missing or unreadable keys are nil, and the engine reports `.missingAPIKey` or similar.
    func makeEngine(_ choice: EngineChoice) -> any RecognitionEngine {
        switch choice {
        case .claude(let model):
            ClaudeEngine(model: model, apiKey: keychain.read(account: KeychainStore.claudeAccount))
        case .localLLM(let modelID):
            LocalLLMEngine(
                baseURL: settings.baseLLMURL,
                modelID: modelID,
                apiKey: keychain.read(account: KeychainStore.llmAccount)
            )
        }
    }

    // MARK: - Capture and session

    private func beginCapture(png: Data, image: NSImage) {
        let choice = settings.engine
        let entry = HistoryEntry(id: UUID(), capturedAt: Date(), kind: .other, engine: choice, text: "")
        do {
            try history.add(entry, png: png)
        } catch {
            NSLog("iCapture failed to add history: %@", String(describing: error))
        }
        refreshRecentEntries()
        currentEntry = entry
        currentPNG = png

        let model = resultWindow.model
        model.image = image
        model.canRecognizeAgain = true
        model.select(choice)
        // A new capture leaves no undo step back to the previous capture's text.
        resultWindow.textController.setStreamingText("")
        showResultWindow()
        startSession(png: png, choice: choice)
    }

    private func startSession(png: Data, choice: EngineChoice) {
        detachSession()
        let session = RecognitionSession(png: png, engine: makeEngine(choice), ocr: VisionOCR())
        self.session = session

        let text = resultWindow.textController
        text.setMarks(confusion: [], revision: [])
        text.isEditable = false
        text.beginReplacement()
        bind(session, entryID: currentEntry?.id)
        resultWindow.model.setSession(session)
        statusMenu?.iconState = .busy
        session.start()
    }

    /// `@Published` fires before the value changes (willSet), so use the received value rather than the session's property.
    /// The session sets text and marks before changing phase last, so the other values are final when phase fires.
    private func bind(_ session: RecognitionSession, entryID: UUID?) {
        let text = resultWindow.textController
        session.$text
            .removeDuplicates()
            .sink { [weak text] value in text?.setStreamingText(value) }
            .store(in: &sessionBindings)
        session.$phase
            .removeDuplicates()
            .sink { [weak self, weak session] phase in
                guard let self, let session else { return }
                self.sessionPhaseChanged(session, to: phase, entryID: entryID)
            }
            .store(in: &sessionBindings)
    }

    private func sessionPhaseChanged(_ session: RecognitionSession, to phase: RecognitionPhase, entryID: UUID?) {
        let text = resultWindow.textController
        switch phase {
        case .reading, .receiving, .verifying:
            text.isEditable = false
            return
        case .done, .failed, .cancelled:
            break
        }

        // Contract: every terminal path must call endReplacement, or undo stays blocked.
        text.endReplacement()
        if phase == .done {
            text.setMarks(confusion: session.confusionMarks, revision: session.revisionMarks)
        }
        text.isEditable = true

        if var entry = currentEntry, entry.id == entryID, phase.shouldReplaceStoredResult(text: session.text) {
            entry.text = session.text
            entry.kind = session.kind
            entry.engine = session.engineChoice
            currentEntry = entry
            cancelPendingEditSave()
            save(entry)
        }

        switch phase {
        case .cancelled:
            statusMenu?.iconState = .idle
        default:
            statusMenu?.iconState = resultWindow.isKeyWindow ? .idle : .doneUnseen
        }
    }

    /// Cancels the running session (its cancel handling saves history) and flushes any pending edit save right away.
    /// Sessions don't cancel themselves on deinit, so always go through this before replacing one or closing the window.
    private func finishCurrentSession() {
        session?.cancel()
        flushPendingEditSave()
    }

    private func detachSession() {
        session?.cancel()
        sessionBindings.removeAll()
        session = nil
        resultWindow.model.setSession(nil)
    }

    // MARK: - Edit saving

    private func userEdited(_ text: String) {
        guard var entry = currentEntry else { return }
        entry.text = text
        currentEntry = entry
        pendingEditSave?.cancel()
        pendingEditSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pendingEditSave = nil
            if let entry = self.currentEntry { self.save(entry) }
        }
    }

    private func flushPendingEditSave() {
        guard pendingEditSave != nil else { return }
        cancelPendingEditSave()
        if let currentEntry { save(currentEntry) }
    }

    private func cancelPendingEditSave() {
        pendingEditSave?.cancel()
        pendingEditSave = nil
    }

    private func save(_ entry: HistoryEntry) {
        do {
            try history.update(entry)
        } catch {
            NSLog("iCapture failed to save history: %@", String(describing: error))
        }
        refreshRecentEntries()
    }

    /// Called after every history write. Reloads the menu's recent list and, if open, the history window.
    private func refreshRecentEntries() {
        statusMenu?.recentEntries = (try? history.entries()) ?? []
        historyWindow.reloadIfVisible()
    }

    /// A cleared entry is never saved again. The result window keeps its text but is detached from history.
    private func clearHistory() {
        cancelPendingEditSave()
        currentEntry = nil
        currentPNG = nil
        resultWindow.model.canRecognizeAgain = false
        do {
            try history.clear()
        } catch {
            NSLog("iCapture failed to clear history: %@", String(describing: error))
        }
        refreshRecentEntries()
    }

    // MARK: - Result window

    private func wireResultWindow() {
        let model = resultWindow.model
        model.onRecognizeAgain = { [weak self] choice in self?.recognizeAgain(with: choice) }
        model.onCancel = { [weak self] in self?.session?.cancel() }
        model.onSkipVerification = { [weak self] in self?.session?.skipVerification() }
        model.onCopyAll = { [weak self] in self?.resultWindow.textController.copyAll() }
        resultWindow.textController.onUserEdit = { [weak self] text in self?.userEdited(text) }
        resultWindow.onClose = { [weak self] in self?.finishCurrentSession() }
        resultWindow.onBecameKey = { [weak self] in
            guard let self, statusMenu?.iconState == .doneUnseen else { return }
            statusMenu?.iconState = .idle
        }
    }

    private func showResultWindow() {
        resultWindow.show()
        refreshLocalLLMModels()
    }

    /// Refetches the local server's model list every time the window opens. On failure the model entries are left out.
    private func refreshLocalLLMModels() {
        llmModelsTask?.cancel()
        let baseURL = settings.baseLLMURL
        let apiKey = keychain.read(account: KeychainStore.llmAccount)
        llmModelsTask = Task { [weak self] in
            let ids = (try? await LocalLLMModels.list(baseURL: baseURL, apiKey: apiKey)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.resultWindow.model.setLocalLLMModels(ids)
        }
    }

    // MARK: - Hotkey and alerts

    private func registerCaptureHotKey(_ combo: HotKeyCombo) throws {
        try hotKeyMonitor.register(combo) { [weak self] in self?.captureRegion() }
    }

    /// Called at launch and when settings recording ends. `settings.hotKey` only ever holds a combo that registered successfully.
    /// On failure (`register` unregisters first, so no hotkey is left), re-registers the previous combo and shows an alert.
    private func applyHotKey(_ combo: HotKeyCombo) {
        let previous = settings.hotKey
        do {
            try registerCaptureHotKey(combo)
            settings.hotKey = combo
            statusMenu?.setCaptureShortcut(combo)
        } catch {
            NSLog("iCapture failed to register hotkey: %@", String(describing: error))
            if combo != previous {
                do {
                    try registerCaptureHotKey(previous)
                } catch {
                    NSLog("iCapture failed to restore previous hotkey: %@", String(describing: error))
                }
            }
            Task { [weak self] in self?.showHotKeyConflictAlert(combo) }
        }
    }

    private func showHotKeyConflictAlert(_ combo: HotKeyCombo) {
        let alert = NSAlert()
        alert.messageText = String(localized: "The \(combo.displayString) shortcut is in use by another app. Choose a different combination in Settings.")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    private func showCaptureFailedAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't capture: \(error.localizedDescription)")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Recording permission is required")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The first time, this adds the app to the list in System Settings. If we already asked, nothing is shown.
        _ = ScreenRecordingPermission.request()
        ScreenRecordingPermission.openSystemSettings()
    }

    // MARK: - History and settings windows

    private func wireHistoryWindow() {
        let model = historyWindow.model
        model.onOpenInResult = { [weak self] entry in self?.reopen(entry) }
        model.onClear = { [weak self] in self?.clearHistory() }
    }

    private func wireSettingsWindow() {
        // Lower the global hotkey while recording so pressing the current combo doesn't start a capture.
        settingsWindow.onHotKeyRecordingStarted = { [weak self] in self?.hotKeyMonitor.unregister() }
        settingsWindow.onHotKeyRecordingEnded = { [weak self] combo in
            guard let self else { return }
            self.applyHotKey(combo ?? self.settings.hotKey)
        }
    }

    @objc private func showHistory() {
        historyWindow.show()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    // MARK: - Main menu

    /// LSUIElement apps show no menu bar, but in-window shortcuts like ⌘C, ⌘Z and ⌘W only work if mainMenu has the items.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "iCapture")
        appMenu.addItem(menuItem(String(localized: "Settings…"), action: #selector(showSettings), key: ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem(String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(menuItem(String(localized: "Undo"), action: Selector(("undo:")), key: "z"))
        editMenu.addItem(menuItem(String(localized: "Redo"), action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem(String(localized: "Cut"), action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem(String(localized: "Copy"), action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem(String(localized: "Paste"), action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem(String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), key: "a"))
        addSubmenu(editMenu, to: mainMenu)

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(menuItem(String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), key: "w"))
        windowMenu.addItem(menuItem(String(localized: "All History…"), action: #selector(showHistory), key: "y", target: self))
        addSubmenu(windowMenu, to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(
        _ title: String, action: Selector, key: String,
        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    // MARK: - Vision warm-up

    /// Vision's first request is slow while it loads its model. Read a tiny image at launch so the first capture isn't delayed.
    private func warmUpVision() {
        guard let png = Self.warmUpPNG() else { return }
        Task.detached(priority: .utility) {
            _ = try? await VisionOCR().recognizeText(png: png)
        }
    }

    private static func warmUpPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 40).fill()
        ("iCapture 1" as NSString).draw(
            at: NSPoint(x: 8, y: 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
