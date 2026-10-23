import AppKit
import Combine

/// 단축키 → 영역 선택 → 캡처 → 인식 세션 → 결과 창 → 이력을 잇는다.
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
    /// 결과 창에 떠 있는 이력 항목과 그 PNG. "다시 인식"과 편집 저장이 이 항목을 덮어쓴다.
    private var currentEntry: HistoryEntry?
    private var currentPNG: Data?
    private var isCapturing = false
    private var pendingEditSave: Task<Void, Never>?
    private var nativModelsTask: Task<Void, Never>?

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
        finishCurrentSession()
        guard ScreenRecordingPermission.isGranted else {
            showPermissionAlert()
            return
        }

        isCapturing = true
        Task {
            defer { isCapturing = false }
            guard let selection = await overlay.selectRegion() else { return }
            do {
                let image = try await ScreenCapturer().capture(rect: selection.rect, on: selection.screen)
                let png = try ImageEncoder.png(from: image)
                beginCapture(png: png, image: NSImage(cgImage: image, size: selection.rect.size))
            } catch {
                NSLog("iCapture 캡처 실패: %@", String(describing: error))
            }
        }
    }

    /// 앱이 끝나기 직전에 부른다. 미뤄 둔 편집을 저장하고, 돌고 있는 세션은 취소해 받은 만큼을 이력에 남기고
    /// (텍스트 없이 취소되면 이전 결과를 지킨다), 설정 창에 입력 중인 키를 확정한다.
    func prepareForTermination() {
        finishCurrentSession()
        settingsWindow.commitPending()
    }

    /// 이력 항목을 세션 없이 결과 창에 다시 연다. 텍스트는 바로 편집할 수 있다.
    func reopen(_ entry: HistoryEntry) {
        finishCurrentSession()
        detachSession()
        // 메뉴의 항목은 마지막 저장 때의 사본이다. 지금 창에 떠 있는 같은 항목이면 그 최신본을 쓴다.
        let entry = currentEntry?.id == entry.id ? currentEntry ?? entry : entry

        let imageURL = history.imageURL(for: entry.id)
        currentEntry = entry
        currentPNG = try? Data(contentsOf: imageURL)

        let text = resultWindow.textController
        text.setMarks(confusion: [], revision: [])
        // 다른 캡처의 텍스트로 돌아가는 undo가 남지 않게 먼저 비운다.
        text.setStreamingText("")
        text.beginReplacement()
        text.setStreamingText(entry.text)
        text.endReplacement()
        text.isEditable = true

        let model = resultWindow.model
        model.image = currentPNG.flatMap { NSImage(data: $0) }
        model.historyEngineName = entry.engineName
        model.canRecognizeAgain = currentPNG != nil
        model.select(Self.choice(named: entry.engineName, in: model.engineOptions) ?? settings.engine)
        statusMenu?.iconState = .idle
        showResultWindow()
    }

    /// 같은 PNG로 새 세션을 돌려 같은 이력 항목을 덮어쓴다. `settings.engine`은 바꾸지 않는다.
    func recognizeAgain(with choice: EngineChoice) {
        guard let png = currentPNG, currentEntry != nil else { return }
        finishCurrentSession()
        startSession(png: png, choice: choice)
    }

    /// 키는 매번 키체인에서 읽는다. 없거나 읽지 못하면 nil이고, 엔진이 `.missingAPIKey` 등으로 알린다.
    func makeEngine(_ choice: EngineChoice) -> any RecognitionEngine {
        switch choice {
        case .claude(let model):
            ClaudeEngine(model: model, apiKey: keychain.read(account: KeychainStore.claudeAccount))
        case .nativ(let modelID):
            NativEngine(
                baseURL: settings.nativBaseURL,
                modelID: modelID,
                apiKey: keychain.read(account: KeychainStore.nativAccount)
            )
        }
    }

    // MARK: - 캡처와 세션

    private func beginCapture(png: Data, image: NSImage) {
        let choice = settings.engine
        let entry = HistoryEntry(id: UUID(), capturedAt: Date(), kind: .other, engineName: choice.displayName, text: "")
        do {
            try history.add(entry, png: png)
        } catch {
            NSLog("iCapture 이력 추가 실패: %@", String(describing: error))
        }
        refreshRecentEntries()
        currentEntry = entry
        currentPNG = png

        let model = resultWindow.model
        model.image = image
        model.canRecognizeAgain = true
        model.select(choice)
        // 새 캡처는 앞 캡처의 텍스트로 돌아가는 undo를 남기지 않는다.
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

    /// `@Published`는 값이 바뀌기 직전(willSet)에 알린다. 그래서 세션의 속성 대신 받은 값을 쓴다.
    /// 세션은 text·표시를 먼저 정하고 phase를 마지막에 바꾸므로, phase 알림 때 나머지 값은 이미 최종값이다.
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

        // 계약: 끝나는 모든 경로에서 endReplacement를 불러야 undo가 다시 풀린다.
        text.endReplacement()
        if phase == .done {
            text.setMarks(confusion: session.confusionMarks, revision: session.revisionMarks)
        }
        text.isEditable = true

        if var entry = currentEntry, entry.id == entryID, phase.shouldReplaceStoredResult(text: session.text) {
            entry.text = session.text
            entry.kind = session.kind
            entry.engineName = session.engineChoice.displayName
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

    /// 돌고 있는 세션을 취소하고(취소 처리에서 이력이 저장된다) 미뤄 둔 편집 저장을 바로 한다.
    /// 세션이 소멸할 때 스스로 취소하지 않으므로, 바꾸거나 창을 닫기 전에 반드시 이걸 거친다.
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

    // MARK: - 편집 저장

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
            NSLog("iCapture 이력 저장 실패: %@", String(describing: error))
        }
        refreshRecentEntries()
    }

    /// 이력을 쓴 뒤마다 부른다. 메뉴의 최근 목록과 (떠 있으면) 이력 창을 다시 읽힌다.
    private func refreshRecentEntries() {
        statusMenu?.recentEntries = (try? history.entries()) ?? []
        historyWindow.reloadIfVisible()
    }

    /// 지운 항목은 다시 저장하지 않는다. 결과 창의 텍스트는 남지만 이력과는 끊긴다.
    private func clearHistory() {
        cancelPendingEditSave()
        currentEntry = nil
        currentPNG = nil
        resultWindow.model.canRecognizeAgain = false
        do {
            try history.clear()
        } catch {
            NSLog("iCapture 이력 비우기 실패: %@", String(describing: error))
        }
        refreshRecentEntries()
    }

    // MARK: - 결과 창

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
        refreshNativModels()
    }

    /// 창을 열 때마다 Nativ 모델 목록을 다시 받는다. 실패하면 Nativ 항목 없이 둔다.
    private func refreshNativModels() {
        nativModelsTask?.cancel()
        let baseURL = settings.nativBaseURL
        let apiKey = keychain.read(account: KeychainStore.nativAccount)
        nativModelsTask = Task { [weak self] in
            let ids = (try? await NativModels.list(baseURL: baseURL, apiKey: apiKey)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.resultWindow.model.setNativModels(ids)
        }
    }

    private static func choice(named name: String, in options: [EngineChoice]) -> EngineChoice? {
        options.first { $0.displayName == name }
    }

    // MARK: - 단축키·알림

    private func registerCaptureHotKey(_ combo: HotKeyCombo) throws {
        try hotKeyMonitor.register(combo) { [weak self] in self?.captureRegion() }
    }

    /// 실행할 때와 설정 창의 녹화가 끝날 때 부른다. `settings.hotKey`는 등록에 성공한 조합만 갖는다.
    /// 실패하면(`register`가 먼저 해제하므로 단축키가 없는 상태) 이전 조합을 다시 등록하고 알린다.
    private func applyHotKey(_ combo: HotKeyCombo) {
        let previous = settings.hotKey
        do {
            try registerCaptureHotKey(combo)
            settings.hotKey = combo
            statusMenu?.setCaptureShortcut(combo)
        } catch {
            NSLog("iCapture 단축키 등록 실패: %@", String(describing: error))
            if combo != previous {
                do {
                    try registerCaptureHotKey(previous)
                } catch {
                    NSLog("iCapture 이전 단축키 복원 실패: %@", String(describing: error))
                }
            }
            Task { [weak self] in self?.showHotKeyConflictAlert(combo) }
        }
    }

    private func showHotKeyConflictAlert(_ combo: HotKeyCombo) {
        let alert = NSAlert()
        alert.messageText = "\(combo.displayString) 단축키를 다른 앱이 쓰고 있어요. 설정에서 다른 조합을 골라 주세요."
        alert.addButton(withTitle: "확인")
        NSApp.activate()
        alert.runModal()
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "화면 기록 권한이 필요해요"
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // 처음이면 시스템 설정의 목록에 이 앱을 올려 둔다. 이미 물어본 적이 있으면 아무것도 띄우지 않는다.
        _ = ScreenRecordingPermission.request()
        ScreenRecordingPermission.openSystemSettings()
    }

    // MARK: - 이력·설정 창

    private func wireHistoryWindow() {
        let model = historyWindow.model
        model.onOpenInResult = { [weak self] entry in self?.reopen(entry) }
        model.onClear = { [weak self] in self?.clearHistory() }
    }

    private func wireSettingsWindow() {
        // 녹화 중에는 전역 단축키를 내려서 지금 조합을 눌러도 캡처가 뜨지 않게 한다.
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

    // MARK: - 메인 메뉴

    /// LSUIElement 앱은 메뉴 막대가 보이지 않지만, 창 안의 ⌘C·⌘Z·⌘W 같은 단축키는 mainMenu에 항목이 있어야 동작한다.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "iCapture")
        appMenu.addItem(menuItem("설정…", action: #selector(showSettings), key: ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("종료", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(menuItem("실행 취소", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(menuItem("실행 복귀", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("오려두기", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem("복사", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem("붙여넣기", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem("전체 선택", action: #selector(NSText.selectAll(_:)), key: "a"))
        addSubmenu(editMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(menuItem("닫기", action: #selector(NSWindow.performClose(_:)), key: "w"))
        windowMenu.addItem(menuItem("모든 이력…", action: #selector(showHistory), key: "y", target: self))
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

    // MARK: - Vision 예열

    /// Vision의 첫 요청은 모델을 올리느라 오래 걸린다. 첫 캡처가 늦지 않게 실행할 때 작은 이미지를 한 번 읽혀 둔다.
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
