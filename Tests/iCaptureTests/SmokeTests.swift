import XCTest

final class SmokeTests: XCTestCase {
    func testTextKindRawValues() {
        XCTAssertEqual(TextKind.allCases.map(\.rawValue), ["sql", "log", "table", "other"])
    }
}
