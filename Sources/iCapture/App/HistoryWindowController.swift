import AppKit
import SwiftUI

/// 이력 창이 보여 줄 상태. 목록은 창을 열 때·key가 될 때·코디네이터가 이력을 쓸 때 다시 읽는다.
@MainActor
final class HistoryModel: ObservableObject {
    /// 최신이 앞.
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var query = ""
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            loadSelectedImage()
        }
    }
    @Published private(set) var selectedImage: NSImage?

    var onOpenInResult: ((HistoryEntry) -> Void)?
    var onClear: (() -> Void)?

    private let history: HistoryStore

    init(history: HistoryStore) {
        self.history = history
    }

    var filteredEntries: [HistoryEntry] {
        entries.filter { $0.matches(query) }
    }

    /// 검색으로 가려진 항목은 오른쪽에 보여 주지 않는다.
    var selectedEntry: HistoryEntry? {
        filteredEntries.first { $0.id == selectedID }
    }

    /// 고른 항목이 사라졌으면(밀려남·비우기) 맨 위 항목을 고른다.
    func reload() {
        entries = (try? history.entries()) ?? []
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        selectedID = entries.first?.id
    }

    private func loadSelectedImage() {
        selectedImage = selectedID.flatMap { NSImage(contentsOf: history.imageURL(for: $0)) }
    }
}

/// 이력 창 하나를 앱이 끝날 때까지 다시 쓴다.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    let model: HistoryModel

    private var window: NSWindow?

    init(history: HistoryStore) {
        model = HistoryModel(history: history)
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = window ?? makeWindow()
        model.reload()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 창이 떠 있을 때만 다시 읽는다. 결과 창이 이력을 저장한 뒤 코디네이터가 부른다.
    func reloadIfVisible() {
        guard isVisible else { return }
        model.reload()
    }

    /// "이력 비우기" 확인 알림. "지우기"를 고르면 `onClear`를 부른다.
    func confirmClear() {
        let count = model.entries.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "이력 \(count)개를 모두 지울까요?"
        let clear = alert.addButton(withTitle: "지우기")
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.onClear?()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "이력"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        let hosting = NSHostingView(rootView: HistoryView(model: model, onClear: { [weak self] in self?.confirmClear() }))
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting
        window.setContentSize(NSSize(width: 880, height: 540))
        window.center()

        self.window = window
        return window
    }
}
