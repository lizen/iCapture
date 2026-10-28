import AppKit

enum StatusIconState {
    case idle, busy, doneUnseen
}

/// The menu bar icon and its menu. The menu is rebuilt with the recent captures every time it opens (`menuNeedsUpdate`).
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onCapture: (@MainActor () -> Void)?
    var onOpenEntry: (@MainActor (HistoryEntry) -> Void)?
    var onShowHistory: (@MainActor () -> Void)?
    var onShowSettings: (@MainActor () -> Void)?

    /// Newest first. The menu shows only the first 5.
    var recentEntries: [HistoryEntry] = []

    var iconState: StatusIconState = .idle {
        didSet {
            guard iconState != oldValue else { return }
            applyIconState()
        }
    }

    private static let recentLimit = 5
    private static let titleLimit = 28

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var captureShortcut = HotKeyCombo.default.menuKeyEquivalent
    private var blinkTimer: Timer?
    private var isDimmed = false

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        applyIconState()
    }

    /// Updates the shortcut shown to the right of "Capture Region" in the menu.
    func setCaptureShortcut(_ combo: HotKeyCombo) {
        captureShortcut = combo.menuKeyEquivalent
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let capture = NSMenuItem(title: String(localized: "Capture Region"), action: #selector(captureSelected), keyEquivalent: captureShortcut.key)
        capture.keyEquivalentModifierMask = captureShortcut.modifiers
        capture.target = self
        menu.addItem(capture)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Recent Captures")))
        let recent = recentEntries.prefix(Self.recentLimit)
        if recent.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No captures yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = AppLanguage.displayLocale
            formatter.unitsStyle = .short
            let now = Date()
            for entry in recent {
                let item = NSMenuItem(title: "", action: #selector(entrySelected(_:)), keyEquivalent: "")
                item.attributedTitle = Self.title(for: entry, relativeTime: formatter.localizedString(for: entry.capturedAt, relativeTo: now))
                item.representedObject = entry.id
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "All History…"), key: "y", action: #selector(historySelected)))
        menu.addItem(item(String(localized: "Settings…"), key: ",", action: #selector(settingsSelected)))

        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - Private

    private func item(_ title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Truncates the first line to 28 characters ("…" when longer) and appends the relative time in gray at the right tab stop.
    private static func title(for entry: HistoryEntry, relativeTime: String) -> NSAttributedString {
        let line = entry.firstLine
        let shown = line.isEmpty ? String(localized: "(no text)") : line.count > titleLimit ? String(line.prefix(titleLimit)) + "…" : line

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 320)]
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: shown + "\t",
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        title.append(NSAttributedString(
            string: relativeTime,
            attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return title
    }

    private func applyIconState() {
        guard let button = statusItem.button else { return }
        blinkTimer?.invalidate()
        blinkTimer = nil
        button.alphaValue = 1

        switch iconState {
        case .idle:
            button.image = Self.baseIcon()
        case .busy:
            button.image = Self.baseIcon()
            startBlinking(button)
        case .doneUnseen:
            button.image = Self.iconWithGreenDot()
        }
    }

    /// Alpha 1.0 <-> 0.35 every 0.8 seconds. Added to the common modes so it keeps running while the menu is open.
    private func startBlinking(_ button: NSStatusBarButton) {
        isDimmed = false
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                self.isDimmed.toggle()
                let target: CGFloat = self.isDimmed ? 0.35 : 1.0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    button.animator().alphaValue = target
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private static func baseIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "iCapture")
        image?.isTemplate = true
        return image
    }

    /// Draws the default icon in the menu bar's text color and puts a green dot at the top right.
    /// Built as a non-template image to keep the dot's color, and painted for the appearance (light or dark) at draw time.
    private static func iconWithGreenDot() -> NSImage? {
        guard let size = baseIcon()?.size else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            guard let base = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) else { return false }
            // The image's drawing buffer starts transparent, so sourceAtop paints only the glyph's pixels.
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)

            let diameter: CGFloat = 6
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = String(localized: "iCapture: new result")
        return image
    }

    @objc private func captureSelected() {
        onCapture?()
    }

    @objc private func entrySelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = recentEntries.first(where: { $0.id == id }) else { return }
        onOpenEntry?(entry)
    }

    @objc private func historySelected() {
        onShowHistory?()
    }

    @objc private func settingsSelected() {
        onShowSettings?()
    }
}
