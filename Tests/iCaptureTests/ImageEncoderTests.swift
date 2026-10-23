import AppKit
import XCTest

final class ImageEncoderTests: XCTestCase {
    func testDownscalesUntilUnderByteLimit() throws {
        let noisy = TestImages.noise(width: 4000, height: 3000)
        let data = try ImageEncoder.png(from: noisy, maxBytes: 1_000_000)
        XCTAssertLessThanOrEqual(data.count, 1_000_000)
        XCTAssertLessThan(try XCTUnwrap(NSBitmapImageRep(data: data)).pixelsWide, 4000)
    }

    func testKeepsSmallImageAtFullResolution() throws {
        let img = TestImages.solid(width: 600, height: 200)
        let data = try ImageEncoder.png(from: img)
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 600)
    }

    func testClampsLongSideToMaxDimension() throws {
        let img = TestImages.solid(width: 1000, height: 100)
        let data = try ImageEncoder.png(from: img, maxDimension: 500)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 500)
        XCTAssertEqual(rep.pixelsHigh, 50)
    }
}
