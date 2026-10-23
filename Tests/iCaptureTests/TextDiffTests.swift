import XCTest
@testable import iCapture

final class TextDiffTests: XCTestCase {
    func testTextDiffMarksChangedChar() {
        XCTAssertEqual(TextDiff.changedRanges(from: "u.1evel", to: "u.level"), [NSRange(location: 2, length: 1)])
    }
}
