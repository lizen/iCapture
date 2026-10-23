import AppKit

@MainActor
final class StatusMenuController {
    private let statusItem: NSStatusItem

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        configureButton()
        statusItem.menu = makeMenu()
    }

    private func configureButton() {
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "iCapture")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let capture = NSMenuItem(title: "영역 캡처", action: nil, keyEquivalent: "2")
        capture.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(capture)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "모든 이력…", action: nil, keyEquivalent: "y"))
        menu.addItem(NSMenuItem(title: "설정…", action: nil, keyEquivalent: ","))

        let quit = NSMenuItem(
            title: "종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }
}
