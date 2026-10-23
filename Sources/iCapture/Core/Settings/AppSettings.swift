import Foundation

/// 엔진 선택·Nativ 주소·단축키. 값이 바뀌면 곧바로 UserDefaults에 저장한다.
/// 저장된 값이 없거나 읽을 수 없으면 기본값을 쓴다.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultNativBaseURL = URL(string: "http://127.0.0.1:8080")!

    private let defaults: UserDefaults

    @Published var engine: EngineChoice {
        didSet { save(engine, forKey: "engine") }
    }
    @Published var nativBaseURL: URL {
        didSet { defaults.set(nativBaseURL.absoluteString, forKey: "nativBaseURL") }
    }
    @Published var hotKey: HotKeyCombo {
        didSet { save(hotKey, forKey: "hotKey") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = Self.load(EngineChoice.self, forKey: "engine", from: defaults) ?? .claude(.sonnet)
        nativBaseURL = defaults.string(forKey: "nativBaseURL").flatMap { URL(string: $0) }.flatMap {
            $0.scheme != nil && $0.host != nil ? $0 : nil
        } ?? Self.defaultNativBaseURL
        hotKey = Self.load(HotKeyCombo.self, forKey: "hotKey", from: defaults) ?? .default
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
