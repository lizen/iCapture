import Carbon.HIToolbox
import XCTest

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
        XCTAssertEqual(s.engine, .localAuto)
        XCTAssertEqual(s.baseLLMURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(s.hotKey, .default)
    }

    func testPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let first = AppSettings(defaults: defaults)
        first.engine = .localLLM(modelID: "qwen")
        first.baseLLMURL = URL(string: "http://192.168.0.5:9000")!
        first.hotKey = HotKeyCombo(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey))

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.engine, .localLLM(modelID: "qwen"))
        XCTAssertEqual(second.baseLLMURL.absoluteString, "http://192.168.0.5:9000")
        XCTAssertEqual(second.hotKey, HotKeyCombo(keyCode: 0, carbonModifiers: UInt32(controlKey | optionKey)))
    }

    /// 이름을 바꾸기 전 버전이 저장한 값(`nativ` 엔진, `nativBaseURL` 키, `nativ-api-key` 계정)을 그대로 읽는다.
    func testReadsValuesSavedBeforeRename() throws {
        let defaults = freshDefaults()
        defaults.set(Data(#"{"nativ":{"modelID":"qwen"}}"#.utf8), forKey: "engine")
        defaults.set("http://127.0.0.1:11434", forKey: "nativBaseURL")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.engine, .localLLM(modelID: "qwen"))
        XCTAssertEqual(settings.baseLLMURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(KeychainStore.llmAccount, "nativ-api-key")

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(EngineChoice.localLLM(modelID: "m")), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""nativ""#), encoded)
    }

    func testCorruptedValuesFallBackToDefaults() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "engine")
        defaults.set(Data("not json".utf8), forKey: "hotKey")
        defaults.set("", forKey: "nativBaseURL")
        let s = AppSettings(defaults: defaults)
        XCTAssertEqual(s.engine, .localAuto)
        XCTAssertEqual(s.baseLLMURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(s.hotKey, .default)
    }
    func testValidatedBaseLLMURL() {
        XCTAssertEqual(AppSettings.validatedBaseLLMURL("http://192.168.0.5:9000")?.absoluteString, "http://192.168.0.5:9000")
        XCTAssertEqual(AppSettings.validatedBaseLLMURL("  https://llm.local  ")?.absoluteString, "https://llm.local")
        XCTAssertNil(AppSettings.validatedBaseLLMURL(""))
        XCTAssertNil(AppSettings.validatedBaseLLMURL("127.0.0.1:8080"))
        XCTAssertNil(AppSettings.validatedBaseLLMURL("ftp://127.0.0.1"))
        XCTAssertNil(AppSettings.validatedBaseLLMURL("http://"))
    }

    func testInvalidStoredBaseLLMURLFallsBackToDefault() {
        let defaults = freshDefaults()
        defaults.set("127.0.0.1:8080", forKey: "nativBaseURL")
        XCTAssertEqual(AppSettings(defaults: defaults).baseLLMURL.absoluteString, "http://127.0.0.1:8080")
    }
}
