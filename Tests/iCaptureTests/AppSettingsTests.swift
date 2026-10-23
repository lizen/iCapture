import Carbon.HIToolbox
import XCTest
@testable import iCapture

@MainActor
final class AppSettingsTests: XCTestCase {
    private var suiteNames: [String] = []

    private func freshDefaults() -> UserDefaults {
        let name = "dev.local.iCapture.tests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
        try await super.tearDown()
    }

    func testDefaults() {
        let s = AppSettings(defaults: freshDefaults())
        XCTAssertEqual(s.engine, .claude(.sonnet))
        XCTAssertEqual(s.nativBaseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(s.hotKey, .default)
    }

    func testPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let first = AppSettings(defaults: defaults)
        first.engine = .nativ(modelID: "qwen")
        first.nativBaseURL = URL(string: "http://192.168.0.5:9000")!
        first.hotKey = HotKeyCombo(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey))

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.engine, .nativ(modelID: "qwen"))
        XCTAssertEqual(second.nativBaseURL.absoluteString, "http://192.168.0.5:9000")
        XCTAssertEqual(second.hotKey, HotKeyCombo(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey)))
    }

    func testCorruptedValuesFallBackToDefaults() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "engine")
        defaults.set(Data("not json".utf8), forKey: "hotKey")
        defaults.set("", forKey: "nativBaseURL")
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.engine, .claude(.sonnet))
        XCTAssertEqual(s.nativBaseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(s.hotKey, .default)
    }
    func testValidatedNativBaseURL() {
        XCTAssertEqual(AppSettings.validatedNativBaseURL("http://192.168.0.5:9000")?.absoluteString, "http://192.168.0.5:9000")
        XCTAssertEqual(AppSettings.validatedNativBaseURL("  https://nativ.local  ")?.absoluteString, "https://nativ.local")
        XCTAssertNil(AppSettings.validatedNativBaseURL(""))
        XCTAssertNil(AppSettings.validatedNativBaseURL("127.0.0.1:8080"))
        XCTAssertNil(AppSettings.validatedNativBaseURL("ftp://127.0.0.1"))
        XCTAssertNil(AppSettings.validatedNativBaseURL("http://"))
    }

    func testInvalidStoredNativURLFallsBackToDefault() {
        let defaults = freshDefaults()
        defaults.set("127.0.0.1:8080", forKey: "nativBaseURL")
        XCTAssertEqual(AppSettings(defaults: defaults).nativBaseURL.absoluteString, "http://127.0.0.1:8080")
    }
}
