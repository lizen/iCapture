import AppKit
import SwiftUI

/// State shown by the history window. The list is reloaded when the window opens, becomes key, or the coordinator writes history.
@MainActor
final class HistoryModel: ObservableObject {
    /// Newest first.
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

    /// Entries hidden by the search are not shown on the right.
    var selectedEntry: HistoryEntry? {
        filteredEntries.first { $0.id == selectedID }
    }

    /// If the selected entry is gone (evicted or cleared), select the top entry.
    func reload() {
        entries = (try? history.entries()) ?? []
        if let selectedID, entries.contains(where: { $0.id == selectedID }) { return }
        selectedID = entries.first?.id
    }

    private func loadSelectedImage() {
        selectedImage = selectedID.flatMap { NSImage(contentsOf: history.imageURL(for: $0)) }
    }
}

/// One history window, reused until the app quits.
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

    /// Reloads only while the window is open. The coordinator calls this after the result window saves history.
    func reloadIfVisible() {
        guard isVisible else { return }
        model.reload()
    }

    /// Confirmation alert for "Clear History". Calls `onClear` when "Delete" is chosen.
    func confirmClear() {
        let count = model.entries.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete all \(count) history entries?")
        let clear = alert.addButton(withTitle: String(localized: "Delete"))
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        window.title = String(localized: "History")
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
