import Foundation

/// Engine choice, local server (Nativ, Ollama, vLLM) URL, hotkey, and UI language. Saved to UserDefaults as soon as a value changes.
/// Defaults are used when nothing is saved or a value can't be read.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultBaseLLMURL = URL(string: "http://127.0.0.1:8080")!

    private let defaults: UserDefaults

    @Published var engine: EngineChoice {
        didSet { save(engine, forKey: "engine") }
    }
    @Published var baseLLMURL: URL {
        didSet { defaults.set(baseLLMURL.absoluteString, forKey: "nativBaseURL") }
    }
    @Published var hotKey: HotKeyCombo {
        didSet { save(hotKey, forKey: "hotKey") }
    }
    /// Also writes the app's `AppleLanguages` override, which macOS applies at the next launch.
    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            if let languages = language.appleLanguages {
                defaults.set(languages, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }
    /// The language the UI was launched with. The UI keeps it until the app restarts.
    let languageAtLaunch: AppLanguage

    var needsRestartForLanguage: Bool { language != languageAtLaunch }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = Self.load(EngineChoice.self, forKey: "engine", from: defaults) ?? .localAuto
        baseLLMURL = defaults.string(forKey: "nativBaseURL").flatMap(Self.validatedBaseLLMURL) ?? Self.defaultBaseLLMURL
        hotKey = Self.load(HotKeyCombo.self, forKey: "hotKey", from: defaults) ?? .default
        let storedLanguage = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = storedLanguage
        languageAtLaunch = storedLanguage
    }

    /// Returns a URL only for a trimmed http or https address with a host; otherwise nil (the settings window keeps the previous value).
    static func validatedBaseLLMURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
