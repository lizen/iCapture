import XCTest

final class ConfusionMarkerTests: XCTestCase {
    func testMarksL1Disagreement() {
        let m = ConfusionMarker.marks(candidate: "WHERE u.level = 1", reference: "WHERE u.1evel = 1", kind: .sql)
        XCTAssertEqual(m, [NSRange(location: 8, length: 1)])  // the 'l' in candidate
    }

    func testNoMarksWhenIdentical() {
        XCTAssertEqual(ConfusionMarker.marks(candidate: "SELECT 1", reference: "SELECT  1", kind: .sql), [])
    }

    func testIgnoresNonConfusableDifferences() {
        XCTAssertEqual(ConfusionMarker.marks(candidate: "회원명", reference: "회원몀", kind: .sql), [])
    }

    func testIgnoresLongGarbledRuns() {
        XCTAssertEqual(ConfusionMarker.marks(candidate: "-- 회원 조회 l", reference: "-- xx yy zz 1l", kind: .sql), [])
    }

    func testTablePipesAreNotMarked() {
        XCTAssertEqual(
            ConfusionMarker.marks(candidate: "| a | b |\n|---|---|\n| 1 | 2 |", reference: "a b\n1 2", kind: .table), [])
    }

    func testUTF16OffsetsAfterKorean() {
        // The two Hangul syllables before 'l' are one UTF-16 unit each
        XCTAssertEqual(
            ConfusionMarker.marks(candidate: "회원 l", reference: "회원 1", kind: .other), [NSRange(location: 3, length: 1)])
    }
}
