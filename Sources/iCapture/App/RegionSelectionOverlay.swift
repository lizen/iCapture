import AppKit

/// An overlay that covers the screen under the mouse and lets the user drag out a region.
@MainActor
final class RegionSelectionOverlay {
    private var panel: OverlayPanel?
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Whether the crosshair cursor was pushed when the overlay appeared. Popped once on close to restore the previous cursor.
    private var pushedCursor = false

    /// The returned rect is in AppKit global coordinates (bottom-left origin, points). nil on esc or a too-small region.
    func selectRegion() async -> (rect: CGRect, screen: NSScreen)? {
        guard continuation == nil else { return nil }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        else { return nil }

        // The app to give focus back to when nothing is selected. Unused when a region is chosen, since the result window activates iCapture.
        let current = NSRunningApplication.current
        let previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == current ? nil : $0 }

        let localRect = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            self.continuation = continuation
            present(on: screen)
        }
        dismiss()

        guard let localRect, !CaptureGeometry.isTooSmall(localRect) else {
            // If cancelled because the user switched apps (iCapture is already inactive), leave the app they chose alone.
            if NSApp.isActive { previousApp?.activate() }
            return nil
        }
        // Give the window server time to redraw so the overlay doesn't end up in the captured image.
        try? await Task.sleep(for: .milliseconds(50))
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
        // NSPanel defaults to true, so it silently hides when the app deactivates. Keep it visible and cancel via the observers below.
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
        // Cursor rects only apply once the app is active and the mouse moves. Menu bar apps aren't always activated right away,
        // so push the crosshair the moment the overlay appears. After that, SelectionView's tracking area keeps it a crosshair.
        NSCursor.crosshair.push()
        pushedCursor = true
    }

    private func finish(with rect: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: rect)
    }

    /// Cancels the selection when the app deactivates or the panel loses key. Otherwise the continuation would never resume.
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
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        // Use the default arrow until the window underneath sets the cursor again after the overlay disappears.
        NSCursor.arrow.set()
    }
}

/// Borderless windows can't become key by default, so allow it explicitly to receive esc.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    /// The selected region in view coordinates (bottom-left origin). nil when cancelled.
    var onFinish: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// Keeps the crosshair while the mouse is over the overlay, even when the app isn't active (`.activeAlways`).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim only outside the selection. The inside stays almost transparent; fully transparent would let clicks fall through, so keep a little alpha.
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
        NSCursor.crosshair.set()
        startPoint = clamped(convert(event.locationInWindow, from: nil))
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        NSCursor.crosshair.set()
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
