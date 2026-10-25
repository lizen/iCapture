import Foundation

/// 엔진 선택·로컬 서버(Nativ·Ollama·vLLM) 주소·단축키. 값이 바뀌면 곧바로 UserDefaults에 저장한다.
/// 저장된 값이 없거나 읽을 수 없으면 기본값을 쓴다.
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = Self.load(EngineChoice.self, forKey: "engine", from: defaults) ?? .localAuto
        baseLLMURL = defaults.string(forKey: "nativBaseURL").flatMap(Self.validatedBaseLLMURL) ?? Self.defaultBaseLLMURL
        hotKey = Self.load(HotKeyCombo.self, forKey: "hotKey", from: defaults) ?? .default
    }

    /// 앞뒤 공백을 지운 뒤 http·https 주소이고 호스트가 있을 때만 URL을 돌려준다. 아니면 nil(설정 창은 이전 값을 지킨다).
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
