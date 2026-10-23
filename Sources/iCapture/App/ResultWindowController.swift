import AppKit
import Combine
import SwiftUI

/// 결과 창이 보여 줄 상태. 진행 중인 세션이 있으면 그 변경을 그대로 전달해 화면을 다시 그리게 한다.
@MainActor
final class ResultModel: ObservableObject {
    /// 로컬 모델(자동)을 맨 앞에 둔다. 기본 엔진이고 비용이 들지 않는다.
    static let baseChoices: [EngineChoice] = [.localAuto, .claude(.sonnet), .claude(.haiku)]

    @Published var image: NSImage?
    /// 이력에서 다시 열었을 때는 nil이다(돌고 있는 세션 없음).
    @Published private(set) var session: RecognitionSession?
    /// 세션 없이 이력을 열었을 때 상태 줄에 보여 줄 엔진 이름.
    @Published var historyEngineName = ""
    @Published var engineOptions: [EngineChoice] = ResultModel.baseChoices
    /// "다시 인식"에만 쓴다. `settings.engine`은 바꾸지 않는다.
    @Published var selectedEngine: EngineChoice = .localAuto
    /// "검사 건너뛰기"를 누른 뒤에는 OCR이 끝날 때까지 `.verifying`이 남아 있어서 버튼을 따로 막는다.
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

    /// 로컬(자동) + Claude 두 개 + 로컬 서버의 모델들. 지금 고른 엔진이 목록에 없으면(예: 로컬 서버가 꺼짐) 끝에 붙여 Picker가 비지 않게 한다.
    func setNativModels(_ ids: [String]) {
        var options = Self.baseChoices + ids.map { EngineChoice.nativ(modelID: $0) }
        if !options.contains(selectedEngine) { options.append(selectedEngine) }
        engineOptions = options
    }

    func select(_ choice: EngineChoice) {
        selectedEngine = choice
        if !engineOptions.contains(choice) { engineOptions.append(choice) }
    }
}

/// 결과 창 하나를 앱이 끝날 때까지 다시 쓴다. 텍스트 영역(`RecognizedTextController`)도 창과 수명을 같이한다.
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
        // 다른 앱이 앞에 있어 활성화가 늦어져도 창은 앞에 보이게 한다.
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

    /// 처음 만든 창은 호스팅 뷰가 아직 배치되지 않아 텍스트 뷰가 창에 붙어 있지 않을 수 있다.
    /// 그러면 first responder가 되지 못해 클릭 전까지 ⌘A·⌘C가 듣지 않으므로, 배치를 끝내고 그래도 안 붙었으면 다음 차례에 다시 한다.
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
        // SwiftUI의 이상적 크기로 창을 줄이거나 늘리지 않게 최소 크기만 따른다.
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setContentSize(NSSize(width: 960, height: 560))
        window.center()

        installEscMonitor(for: window)
        self.window = window
        return window
    }

    /// 텍스트 뷰가 first responder면 esc가 `cancelOperation:`(자동 완성)으로 먹힌다.
    /// 그래서 진행 중에는 이 창의 esc를 먼저 가로채 취소로 쓴다.
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
