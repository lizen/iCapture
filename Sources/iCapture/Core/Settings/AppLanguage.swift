import Foundation

/// The app's UI language. `.system` follows the macOS language list; the others override it for this app only.
/// macOS reads the override (`AppleLanguages`) at launch, so a change applies the next time the app opens.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case korean = "ko"

    var id: Self { self }

    /// The `AppleLanguages` value for this choice. nil means "follow macOS".
    var appleLanguages: [String]? {
        self == .system ? nil : [rawValue]
    }

    /// Language names are shown in their own language so they stay recognizable whichever language is active.
    var displayName: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .korean: "한국어"
        }
    }

    /// Locale for dates and relative times, matching the language the UI actually launched with.
    static var displayLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }
}
