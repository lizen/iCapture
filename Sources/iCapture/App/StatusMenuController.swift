import AppKit

enum StatusIconState {
    case idle, busy, doneUnseen
}

/// 메뉴 막대 아이콘과 그 메뉴. 메뉴는 열 때마다(`menuNeedsUpdate`) 최근 캡처 목록과 함께 다시 만든다.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onCapture: (@MainActor () -> Void)?
    var onOpenEntry: (@MainActor (HistoryEntry) -> Void)?
    var onShowHistory: (@MainActor () -> Void)?
    var onShowSettings: (@MainActor () -> Void)?

    /// 최신이 앞. 메뉴에는 앞의 5개만 보여 준다.
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

    /// 메뉴의 "영역 캡처" 오른쪽에 보이는 단축키 표시를 바꾼다.
    func setCaptureShortcut(_ combo: HotKeyCombo) {
        captureShortcut = combo.menuKeyEquivalent
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let capture = NSMenuItem(title: "영역 캡처", action: #selector(captureSelected), keyEquivalent: captureShortcut.key)
        capture.keyEquivalentModifierMask = captureShortcut.modifiers
        capture.target = self
        menu.addItem(capture)

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "최근 캡처"))
        let recent = recentEntries.prefix(Self.recentLimit)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "아직 캡처가 없어요", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
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
        menu.addItem(item("모든 이력…", key: "y", action: #selector(historySelected)))
        menu.addItem(item("설정…", key: ",", action: #selector(settingsSelected)))

        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    // MARK: - Private

    private func item(_ title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 첫 줄을 28자로 자르고(넘치면 "…"), 오른쪽 탭 위치에 상대 시각을 회색으로 붙인다.
    private static func title(for entry: HistoryEntry, relativeTime: String) -> NSAttributedString {
        let line = entry.firstLine
        let shown = line.isEmpty ? "(텍스트 없음)" : line.count > titleLimit ? String(line.prefix(titleLimit)) + "…" : line

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

    /// 0.8초 주기로 alpha 1.0 ↔ 0.35. 메뉴가 열려 있는 동안에도 돌도록 common 모드에 건다.
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

    /// 기본 아이콘을 메뉴 막대의 글자색으로 칠하고 오른쪽 위에 초록 점을 얹는다.
    /// 점 색을 지키려고 template이 아닌 이미지로 만들고, 그리는 시점의 모양(라이트·다크)에 맞춰 칠한다.
    private static func iconWithGreenDot() -> NSImage? {
        guard let size = baseIcon()?.size else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            guard let base = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) else { return false }
            // 이 이미지의 그리기 버퍼는 투명하게 시작하므로 sourceAtop은 글리프 픽셀만 칠한다.
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
        image.accessibilityDescription = "iCapture: 새 결과"
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
