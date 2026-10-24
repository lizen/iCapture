import XCTest

final class SpreadsheetHeaderCleanupTests: XCTestCase {
    func testRemovesColumnLettersAndRowNumbers() {
        let model = """
        | | A | B | C | D |
        | --- | --- | --- | --- | --- |
        | 1 | 이름 | 부서 | 입사일 | 급여 |
        | 2 | 김민수 | 개발 | 2021-03-02 | 4,200,000 |
        | 3 | 이서연 | | 2022-07-15 | 3,800,000 |
        """
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(model), """
        | 이름 | 부서 | 입사일 | 급여 |
        |---|---|---|---|
        | 김민수 | 개발 | 2021-03-02 | 4,200,000 |
        | 이서연 |  | 2022-07-15 | 3,800,000 |
        """)
    }

    func testRemovesColumnLettersStartingMidSheet() {
        let model = """
        | C | D |
        |---|---|
        | 부서 | 급여 |
        | 개발 | 100 |
        """
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(model), """
        | 부서 | 급여 |
        |---|---|
        | 개발 | 100 |
        """)
    }

    func testRemovesRowNumbersWithoutLetterHeader() {
        let model = """
        |  | 이름 | 점수 |
        |---|---|---|
        | 7 | 가 | 10 |
        | 8 | 나 | 20 |
        """
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(model), """
        | 이름 | 점수 |
        |---|---|
        | 가 | 10 |
        | 나 | 20 |
        """)
    }

    func testLeavesOrdinaryTablesAlone() {
        let numbered = """
        | No. | 이름 |
        |---|---|
        | 1 | 가 |
        | 2 | 나 |
        """
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(numbered), numbered)

        let plain = """
        | 컬럼명 | 타입 | 설명 |
        |---|---|---|
        | user_id | BIGINT | 회원 ID |
        """
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(plain), plain)
    }

    func testHugeNumbersDoNotCrash() {
        let table = """
        |  | 이름 |
        |---|---|
        | \(Int.max) | 가 |
        | 1 | 나 |
        """
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(table), table)
    }

    func testLeavesNonTableTextAlone() {
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean("SELECT 1\nFROM dual"), "SELECT 1\nFROM dual")
        XCTAssertEqual(SpreadsheetHeaderCleanup.clean(""), "")
    }

    func testParseCompleteCleansTables() {
        let raw = "<<KIND:table>>\n| | A | B |\n|---|---|---|\n| 1 | x | y |\n| 2 | p | q |"
        XCTAssertEqual(KindTagParser.parseComplete(raw).body, "| x | y |\n|---|---|\n| p | q |")
        let sql = "<<KIND:sql>>\n| | A | B |"
        XCTAssertEqual(KindTagParser.parseComplete(sql).body, "| | A | B |")
    }
}
