import AppKit
import ServiceManagement
import SwiftUI

/// State shown by the settings window. Engine and hotkey use `AppSettings` directly; values edited only inside the window live here.
/// Keys are written to the Keychain on commit (Return, the window losing key, or closing), not on every keystroke.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var claudeKey = ""
    @Published var llmKey = ""
    @Published var baseLLMURLText = ""
    @Published var llmModelIDs: [String] = []
    @Published var isRecordingHotKey = false
    @Published var launchAtLogin = false

    var onCommit: (() -> Void)?
    var onToggleRecording: (() -> Void)?
    var onSetLaunchAtLogin: ((Bool) -> Void)?
    var onRelaunch: (() -> Void)?

    /// Local (auto) + two Claude models + the local server's models. If the selected engine isn't listed (e.g. the server is down), it's appended so the Picker isn't empty.
    func engineOptions(selected: EngineChoice) -> [EngineChoice] {
        var options = ResultModel.baseChoices + llmModelIDs.map { EngineChoice.localLLM(modelID: $0) }
        if !options.contains(selected) { options.append(selected) }
        return options
    }
}

/// One settings window, reused until the app quits. Hotkey recording happens here too.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()

    /// Recording started. The coordinator lowers the global hotkey so no capture starts while recording.
    var onHotKeyRecordingStarted: (() -> Void)?
    /// Recording ended. nil means cancelled (esc, window closed, etc.), so re-register the original combo.
    var onHotKeyRecordingEnded: ((HotKeyCombo?) -> Void)?

    private let settings: AppSettings
    private let keychain: KeychainStore
    private var window: NSWindow?
    private var recordingMonitor: Any?
    private var llmModelsTask: Task<Void, Never>?
    /// The value last read from or written to the Keychain. Not rewritten if unchanged.
    private var savedClaudeKey = ""
    private var savedLLMKey = ""

    init(settings: AppSettings, keychain: KeychainStore) {
        self.settings = settings
        self.keychain = keychain
        super.init()
        model.onCommit = { [weak self] in self?.commit() }
        model.onToggleRecording = { [weak self] in self?.toggleRecording() }
        model.onSetLaunchAtLogin = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
        model.onRelaunch = { AppRelauncher.relaunch() }
    }

    /// Called right before the app quits. Quitting skips `windowWillClose`, so keys and URL being typed are committed here.
    func commitPending() {
        guard window?.isVisible == true else { return }
        commit()
    }

    func show() {
        let window = window ?? makeWindow()
        // If already open, don't reload, so values being edited are kept.
        if !window.isVisible { load() }
        AppSwitcher.show(window)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Switching to another app ends recording and restores the global hotkey.
        stopRecording(with: nil)
        commit()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(with: nil)
        commit()
        // Don't keep keys in memory while the window is closed. They're read from the Keychain on reopen.
        model.claudeKey = ""
        model.llmKey = ""
        savedClaudeKey = ""
        savedLLMKey = ""
        AppSwitcher.windowWillClose(notification)
    }

    // MARK: - Reading and committing values

    private func load() {
        savedClaudeKey = keychain.read(account: KeychainStore.claudeAccount) ?? ""
        savedLLMKey = keychain.read(account: KeychainStore.llmAccount) ?? ""
        model.claudeKey = savedClaudeKey
        model.llmKey = savedLLMKey
        model.baseLLMURLText = settings.baseLLMURL.absoluteString
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshLocalLLMModels()
    }

    private func commit() {
        var llmChanged = false
        // Whitespace and newlines that came along with a paste aren't part of the key.
        let claudeKey = model.claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let llmKey = model.llmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.claudeKey != claudeKey { model.claudeKey = claudeKey }
        if model.llmKey != llmKey { model.llmKey = llmKey }
        if claudeKey != savedClaudeKey {
            writeKey(claudeKey, account: KeychainStore.claudeAccount)
            savedClaudeKey = claudeKey
        }
        if llmKey != savedLLMKey {
            writeKey(llmKey, account: KeychainStore.llmAccount)
            savedLLMKey = llmKey
            llmChanged = true
        }
        // Ignore an invalid URL and show the previous value again.
        if let url = AppSettings.validatedBaseLLMURL(model.baseLLMURLText) {
            if url != settings.baseLLMURL {
                settings.baseLLMURL = url
                llmChanged = true
            }
        }
        model.baseLLMURLText = settings.baseLLMURL.absoluteString
        if llmChanged { refreshLocalLLMModels() }
    }

    /// Never log key values.
    private func writeKey(_ value: String, account: String) {
        do {
            try keychain.write(value, account: account)
        } catch {
            NSLog("iCapture failed to save to Keychain (%@): %@", account, String(describing: error))
        }
    }

    /// For the engine Picker. If the list can't be fetched, the local server's model entries are left out.
    private func refreshLocalLLMModels() {
        llmModelsTask?.cancel()
        let baseURL = settings.baseLLMURL
        let apiKey = keychain.read(account: KeychainStore.llmAccount)
        llmModelsTask = Task { [weak self] in
            let ids = (try? await LocalLLMModels.list(baseURL: baseURL, apiKey: apiKey)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.model.llmModelIDs = ids
        }
    }

    // MARK: - Hotkey recording

    private func toggleRecording() {
        if model.isRecordingHotKey {
            stopRecording(with: nil)
        } else {
            startRecording()
        }
    }

    /// While recording, every keyDown in this app is consumed (menu shortcuts become recordable too).
    /// esc cancels; combos without ⌘, ⌃ or ⌥ (`HotKeyCombo(event:)` is nil) are ignored and recording continues.
    private func startRecording() {
        guard !model.isRecordingHotKey else { return }
        model.isRecordingHotKey = true
        onHotKeyRecordingStarted?()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let combo = HotKeyCombo(event: event)
            MainActor.assumeIsolated {
                guard let self else { return }
                if keyCode == 53 {
                    self.stopRecording(with: nil)
                } else if let combo {
                    self.stopRecording(with: combo)
                }
            }
            return nil
        }
    }

    private func stopRecording(with combo: HotKeyCombo?) {
        guard model.isRecordingHotKey else { return }
        model.isRecordingHotKey = false
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        onHotKeyRecordingEnded?(combo)
    }

    // MARK: - Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't change Launch at Login")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        // The window size follows the SwiftUI form (the hosting controller's preferredContentSize).
        let hosting = NSHostingController(rootView: SettingsView(model: model, settings: settings))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.center()

        self.window = window
        return window
    }
}
