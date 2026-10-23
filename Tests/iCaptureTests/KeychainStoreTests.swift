import XCTest
@testable import iCapture

final class KeychainStoreTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let k = KeychainStore(service: "dev.local.iCapture.tests.\(UUID())")
        defer { try? k.write(nil, account: "a"); try? k.write(nil, account: "b") }

        XCTAssertNil(k.read(account: "a"))
        try k.write("secret", account: "a")
        XCTAssertEqual(k.read(account: "a"), "secret")

        try k.write("changed", account: "a")
        XCTAssertEqual(k.read(account: "a"), "changed")

        try k.write("other", account: "b")
        XCTAssertEqual(k.read(account: "b"), "other")
        XCTAssertEqual(k.read(account: "a"), "changed")

        try k.write(nil, account: "a")
        XCTAssertNil(k.read(account: "a"))
        try k.write("", account: "b")
        XCTAssertNil(k.read(account: "b"))
        XCTAssertNoThrow(try k.write(nil, account: "a"))
    }
}
