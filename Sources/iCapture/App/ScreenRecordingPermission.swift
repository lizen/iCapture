import AppKit
import CoreGraphics

enum ScreenRecordingPermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system permission prompt. Returns true if already granted.
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
