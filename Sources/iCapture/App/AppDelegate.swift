import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenuController: StatusMenuController?
    // TEMP(Task 11): 아래 디버그 연결 전체는 AppCoordinator로 대체한다.
    private let hotKeyMonitor = HotKeyMonitor()
    private let overlay = RegionSelectionOverlay()
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenuController = StatusMenuController(statusItem: statusItem)

        // TEMP(Task 11)
        statusMenuController?.onCaptureRequested = { [weak self] in self?.debugCapture() }
        do {
            try hotKeyMonitor.register(.default) { [weak self] in self?.debugCapture() }
        } catch {
            NSLog("iCapture 단축키 등록 실패: %@", String(describing: error))
        }
    }

    // TEMP(Task 11): 권한 확인 → 영역 선택 → 캡처 → ~/Desktop/icapture-debug.png 저장.
    private func debugCapture() {
        guard !isCapturing else { return }
        guard ScreenRecordingPermission.isGranted else {
            _ = ScreenRecordingPermission.request()
            return
        }
        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            guard let selection = await overlay.selectRegion() else { return }
            do {
                let image = try await ScreenCapturer().capture(rect: selection.rect, on: selection.screen)
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/icapture-debug.png")
                try data?.write(to: url)
            } catch {
                NSLog("iCapture 디버그 캡처 실패: %@", String(describing: error))
            }
        }
    }
}
