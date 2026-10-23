import XCTest
@testable import iCapture

final class VisionOCRTests: XCTestCase {
    func testVisionReadsRenderedText() async throws {
        let png = TestImages.text("SELECT name FROM users", pointSize: 28)
        let text = try await VisionOCR().recognizeText(png: png)
        XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("SELECTnameFROMusers"), "읽은 결과: \(text)")
    }
}
