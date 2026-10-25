import AppKit
import ServiceManagement
import SwiftUI

/// 설정 창이 보여 줄 상태. 엔진·단축키는 `AppSettings`를 그대로 쓰고, 여기에는 창 안에서만 고치는 값을 둔다.
/// 키는 입력할 때마다가 아니라 확정할 때(Return·창이 key를 잃거나 닫힐 때) 키체인에 쓴다.
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

    /// 로컬(자동) + Claude 두 개 + 로컬 서버의 모델들. 지금 고른 엔진이 목록에 없으면(예: 로컬 서버가 꺼짐) 끝에 붙여 Picker가 비지 않게 한다.
    func engineOptions(selected: EngineChoice) -> [EngineChoice] {
        var options = ResultModel.baseChoices + llmModelIDs.map { EngineChoice.localLLM(modelID: $0) }
        if !options.contains(selected) { options.append(selected) }
        return options
    }
}

/// 설정 창 하나를 앱이 끝날 때까지 다시 쓴다. 단축키 녹화도 여기서 한다.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()

    /// 녹화를 시작했다. 코디네이터는 전역 단축키를 잠시 내려 녹화 중 캡처가 뜨지 않게 한다.
    var onHotKeyRecordingStarted: (() -> Void)?
    /// 녹화가 끝났다. nil이면 취소(esc·창 닫힘 등)라 원래 조합을 다시 등록하면 된다.
    var onHotKeyRecordingEnded: ((HotKeyCombo?) -> Void)?

    private let settings: AppSettings
    private let keychain: KeychainStore
    private var window: NSWindow?
    private var recordingMonitor: Any?
    private var llmModelsTask: Task<Void, Never>?
    /// 마지막으로 키체인에서 읽거나 쓴 값. 바뀌지 않았으면 다시 쓰지 않는다.
    private var savedClaudeKey = ""
    private var savedLLMKey = ""

    init(settings: AppSettings, keychain: KeychainStore) {
        self.settings = settings
        self.keychain = keychain
        super.init()
        model.onCommit = { [weak self] in self?.commit() }
        model.onToggleRecording = { [weak self] in self?.toggleRecording() }
        model.onSetLaunchAtLogin = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
    }

    /// 앱이 끝나기 직전에 부른다. 종료는 `windowWillClose`를 거치지 않으므로 입력 중인 키·주소를 여기서 확정한다.
    func commitPending() {
        guard window?.isVisible == true else { return }
        commit()
    }

    func show() {
        let window = window ?? makeWindow()
        // 이미 떠 있으면 고치던 값을 지키려고 다시 읽지 않는다.
        if !window.isVisible { load() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // 다른 앱으로 가면 녹화를 접어 전역 단축키를 되살린다.
        stopRecording(with: nil)
        commit()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(with: nil)
        commit()
        // 창이 닫혀 있는 동안 키를 메모리에 두지 않는다. 다시 열면 키체인에서 읽는다.
        model.claudeKey = ""
        model.llmKey = ""
        savedClaudeKey = ""
        savedLLMKey = ""
    }

    // MARK: - 값 읽기·확정

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
        // 붙여 넣을 때 딸려 온 공백·줄바꿈은 키가 아니다.
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
        // 잘못된 주소는 무시하고 이전 값으로 되돌려 보여 준다.
        if let url = AppSettings.validatedBaseLLMURL(model.baseLLMURLText) {
            if url != settings.baseLLMURL {
                settings.baseLLMURL = url
                llmChanged = true
            }
        }
        model.baseLLMURLText = settings.baseLLMURL.absoluteString
        if llmChanged { refreshLocalLLMModels() }
    }

    /// 키 값은 로그에 남기지 않는다.
    private func writeKey(_ value: String, account: String) {
        do {
            try keychain.write(value, account: account)
        } catch {
            NSLog("iCapture 키체인 저장 실패(%@): %@", account, String(describing: error))
        }
    }

    /// 엔진 Picker용. 받지 못하면 로컬 서버의 모델 항목 없이 둔다.
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

    // MARK: - 단축키 녹화

    private func toggleRecording() {
        if model.isRecordingHotKey {
            stopRecording(with: nil)
        } else {
            startRecording()
        }
    }

    /// 녹화 중에는 이 앱의 keyDown을 모두 먹는다(메뉴 단축키도 녹화 대상이 된다).
    /// esc는 취소, ⌘·⌃·⌥가 없는 조합(`HotKeyCombo(event:)`가 nil)은 무시하고 계속 기다린다.
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

    // MARK: - 로그인할 때 자동 실행

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인할 때 자동 실행을 바꾸지 못했어요"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        // 창 크기는 SwiftUI 폼의 크기를 따른다(호스팅 컨트롤러의 preferredContentSize).
        let hosting = NSHostingController(rootView: SettingsView(model: model, settings: settings))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "설정"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.center()

        self.window = window
        return window
    }
}
