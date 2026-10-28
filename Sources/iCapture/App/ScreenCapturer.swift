import AppKit
import ScreenCaptureKit

enum CaptureError: Error {
    case displayNotFound
}

@MainActor
struct ScreenCapturer {
    /// `rect` is in AppKit global coordinates (bottom-left origin, points). The result is a CGImage at Retina resolution.
    func capture(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw CaptureError.displayNotFound
        }
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CaptureGeometry.displayLocalRect(selection: rect, screenFrame: screen.frame)
        configuration.width = Int((rect.width * scale).rounded())
        configuration.height = Int((rect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
