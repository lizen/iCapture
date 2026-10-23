import AppKit

/// 마우스가 있는 화면 하나를 덮고, 드래그로 영역을 고르게 하는 오버레이.
@MainActor
final class RegionSelectionOverlay {
    private var panel: OverlayPanel?
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var observers: [NSObjectProtocol] = []

    /// 반환하는 rect는 AppKit 전역 좌표(왼쪽 아래 원점, 포인트). esc나 너무 작은 영역이면 nil.
    func selectRegion() async -> (rect: CGRect, screen: NSScreen)? {
        guard continuation == nil else { return nil }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        else { return nil }

        let localRect = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            self.continuation = continuation
            present(on: screen)
        }
        dismiss()
        // 오버레이가 캡처 이미지에 찍히지 않도록 윈도우 서버가 화면을 갱신할 시간을 준다.
        try? await Task.sleep(for: .milliseconds(50))

        guard let localRect, !CaptureGeometry.isTooSmall(localRect) else { return nil }
        return (localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), screen)
    }

    private func present(on screen: NSScreen) {
        let panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        // NSPanel은 기본값이 true라 앱이 비활성화되면 조용히 숨는다. 숨기지 않고 아래 관찰자로 취소한다.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(with: rect) }
        panel.contentView = view

        self.panel = panel
        observeDeactivation(of: panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    private func finish(with rect: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: rect)
    }

    /// 앱이 비활성화되거나 패널이 key를 잃으면 선택을 취소한다. 그렇지 않으면 continuation이 영영 resume되지 않는다.
    private func observeDeactivation(of panel: NSPanel) {
        let center = NotificationCenter.default
        let cancel: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(with: nil) }
        }
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: cancel),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main, using: cancel),
        ]
    }

    private func dismiss() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 테두리 없는 창은 기본적으로 key가 될 수 없어서 esc를 받으려면 따로 허용해야 한다.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    /// 뷰 좌표(왼쪽 아래 원점)의 선택 영역. 취소면 nil.
    var onFinish: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 선택 영역 바깥만 어둡게 칠한다. 안쪽은 거의 투명하게 두되, 완전 투명이면 클릭이 뒤로 새서 알파를 살짝 남긴다.
        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.25).setFill()
        dim.fill()

        guard let selection else { return }
        NSColor.white.withAlphaComponent(0.01).setFill()
        selection.fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = clamped(convert(event.locationInWindow, from: nil))
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let current = clamped(convert(event.locationInWindow, from: nil))
        selection = CGRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let result = selection
        startPoint = nil
        selection = nil
        onFinish?(result)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // esc
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
