import AppKit
import Carbon.HIToolbox
import XCTest

final class HotKeyComboTests: XCTestCase {
    private func event(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        )!
    }

    func testDefaultHotKeyDisplay() {
        XCTAssertEqual(HotKeyCombo.default.displayString, "⇧⌘2")
    }

    func testDisplayStringUsesAppleModifierOrder() {
        let all = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘A")
    }

    func testDisplayStringKeyLabels() {
        func label(_ code: Int) -> String {
            HotKeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(cmdKey)).displayString
        }
        XCTAssertEqual(label(kVK_F5), "⌘F5")
        XCTAssertEqual(label(kVK_Space), "⌘Space")
        XCTAssertEqual(label(kVK_Return), "⌘↩")
        XCTAssertEqual(label(kVK_ANSI_Grave), "⌘`")
        XCTAssertEqual(label(kVK_ANSI_Slash), "⌘/")
        XCTAssertEqual(label(200), "⌘Key 200")
    }

    func testMenuKeyEquivalent() {
        XCTAssertEqual(HotKeyCombo.default.menuKeyEquivalent.key, "2")
        XCTAssertEqual(HotKeyCombo.default.menuKeyEquivalent.modifiers, [.command, .shift])
        let letter = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(optionKey | controlKey))
        XCTAssertEqual(letter.menuKeyEquivalent.key, "k")
        XCTAssertEqual(letter.menuKeyEquivalent.modifiers, [.option, .control])
        let f5 = HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(f5.menuKeyEquivalent.key, "")
    }

    func testInitFromEventMapsModifiersAndKeyCode() throws {
        let combo = try XCTUnwrap(HotKeyCombo(event: event(keyCode: 19, flags: [.command, .shift])))
        XCTAssertEqual(combo, .default)
    }

    func testInitFromEventRejectsShiftOnlyAndNoModifiers() {
        XCTAssertNil(HotKeyCombo(event: event(keyCode: 19, flags: [.shift])))
        XCTAssertNil(HotKeyCombo(event: event(keyCode: 19, flags: [])))
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(HotKeyCombo.default)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyCombo.self, from: data), .default)
    }
}
