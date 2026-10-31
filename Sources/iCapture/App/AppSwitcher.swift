import AppKit

/// iCapture stays in the menu bar, but behaves like a regular app while one of its windows is open, so ⌘Tab can reach it.
/// macOS has no way to appear in ⌘Tab without also showing a Dock icon.
@MainActor
enum AppSwitcher {
    /// Set the policy before activating, or the app's menu bar may not appear.
    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Keep the window in front even if activation is delayed because another app is frontmost.
        window.orderFrontRegardless()
    }

    /// Call from `windowWillClose`, when the closing window still counts as visible. Windows hidden during region selection don't close.
    static func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let isLastWindow = !NSApp.windows.contains { window in
            window !== closing && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
        if isLastWindow { NSApp.setActivationPolicy(.accessory) }
    }
}
