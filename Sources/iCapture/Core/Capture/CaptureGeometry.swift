import CoreGraphics

enum CaptureGeometry {
    /// 선택 영역을 그 화면 기준 왼쪽 위 원점 좌표(포인트)로 바꾼다.
    /// - Parameters:
    ///   - selection: AppKit 전역 좌표(왼쪽 아래 원점)의 선택 영역
    ///   - screenFrame: 그 화면의 `NSScreen.frame`(AppKit 전역 좌표)
    static func displayLocalRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: selection.minX - screenFrame.minX,
            y: screenFrame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }

    /// 너비나 높이가 4pt보다 작으면 너무 작은 선택으로 본다.
    static func isTooSmall(_ rect: CGRect) -> Bool {
        rect.width < minimumSide || rect.height < minimumSide
    }

    private static let minimumSide: CGFloat = 4
}
