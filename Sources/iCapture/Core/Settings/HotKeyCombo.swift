import AppKit
import Carbon.HIToolbox

/// 전역 단축키 하나를 나타낸다. `carbonModifiers`는 Carbon 비트마스크(`cmdKey` 등)다.
struct HotKeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey))

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// ⌘·⌃·⌥ 중 하나도 눌려 있지 않으면(⇧만으로는 부족) nil.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    /// 애플 표기 순서(⌃⌥⇧⌘) + 키 글자. 기본값은 "⇧⌘2".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Self.keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    /// `NSMenuItem`용. 글자가 없는 키(F키, Space 등)는 key가 빈 문자열이다.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return (Self.characters[keyCode] ?? "", flags)
    }

    /// 글자로 표현되는 키(영문·숫자·기호). 값은 소문자/기호 그대로.
    private static let characters: [UInt32: String] = {
        let table: [(Int, String)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"),
            (kVK_ANSI_E, "e"), (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"),
            (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"),
            (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"), (kVK_ANSI_P, "p"),
            (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"),
            (kVK_ANSI_Y, "y"), (kVK_ANSI_Z, "z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
        ]
        return Dictionary(uniqueKeysWithValues: table.map { (UInt32($0.0), $0.1) })
    }()

    private static let keyLabels: [UInt32: String] = {
        var labels = characters.mapValues { $0.uppercased() }
        let named: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"),
            (kVK_Delete, "⌫"), (kVK_Escape, "⎋"),
        ]
        for (code, label) in named { labels[UInt32(code)] = label }
        return labels
    }()
}
