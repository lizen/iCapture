import XCTest

final class CaptureGeometryTests: XCTestCase {
    func testFlipsToTopLeftLocal() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(
            CaptureGeometry.displayLocalRect(selection: CGRect(x: 100, y: 800, width: 200, height: 50), screenFrame: screen),
            CGRect(x: 100, y: 132, width: 200, height: 50)
        )
    }

    func testSecondaryScreenOffset() {
        let screen = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(
            CaptureGeometry.displayLocalRect(selection: CGRect(x: 1612, y: 780, width: 100, height: 100), screenFrame: screen),
            CGRect(x: 100, y: 0, width: 100, height: 100)
        )
    }

    func testTinySelectionIsRejected() {
        XCTAssertTrue(CaptureGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 3, height: 40)))
        XCTAssertFalse(CaptureGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }
}
