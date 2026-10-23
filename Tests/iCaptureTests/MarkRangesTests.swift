import XCTest

final class MarkRangesTests: XCTestCase {
    func testAdjustShiftsLaterMarks() {
        XCTAssertEqual(
            MarkRanges.adjust([NSRange(location: 10, length: 1)], editedRange: NSRange(location: 0, length: 3), changeInLength: 2),
            [NSRange(location: 12, length: 1)])
    }

    func testAdjustKeepsMarkWhenTypingRightAfterIt() {
        XCTAssertEqual(
            MarkRanges.adjust([NSRange(location: 4, length: 1)], editedRange: NSRange(location: 5, length: 1), changeInLength: 1),
            [NSRange(location: 4, length: 1)])
    }

    func testAdjustDropsEditedMark() {
        XCTAssertEqual(
            MarkRanges.adjust([NSRange(location: 4, length: 1)], editedRange: NSRange(location: 4, length: 1), changeInLength: 0),
            [])
    }
}
