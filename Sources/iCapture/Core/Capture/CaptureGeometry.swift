import CoreGraphics

enum CaptureGeometry {
    /// Converts the selection to that screen's top-left-origin coordinates (points).
    /// - Parameters:
    ///   - selection: The selection in AppKit global coordinates (bottom-left origin)
    ///   - screenFrame: That screen's `NSScreen.frame` (AppKit global coordinates)
    static func displayLocalRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: selection.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    /// A selection narrower or shorter than 4pt is treated as too small.
    static func isTooSmall(_ rect: CGRect) -> Bool {
        rect.width < minimumSide || rect.height < minimumSide
    }

    private static let minimumSide: CGFloat = 4
}
