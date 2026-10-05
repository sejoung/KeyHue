import CoreGraphics
import Testing
@testable import KeyHueApp

@Suite("Previous input source shortcut")
struct InputSourceShortcutTests {
    private static func hotKeys(enabled: Bool = true, type: String = "standard", keyCode: Int = 49,
                                flags: Int = 1_048_576) -> [String: Any] {
        ["60": ["enabled": enabled, "value": ["type": type, "parameters": [65_535, keyCode, flags]]]]
    }

    @Test func commandSpaceIsRead() {
        let shortcut = InputSourceShortcut(symbolicHotKeys: Self.hotKeys())
        #expect(shortcut == InputSourceShortcut(keyCode: 49, flags: CGEventFlags.maskCommand.rawValue))
    }

    @Test func controlSpaceIsRead() {
        let shortcut = InputSourceShortcut(symbolicHotKeys: Self.hotKeys(flags: 262_144))
        #expect(shortcut?.flags == CGEventFlags.maskControl.rawValue)
    }

    @Test func disabledShortcutIsNotUsed() {
        #expect(InputSourceShortcut(symbolicHotKeys: Self.hotKeys(enabled: false)) == nil)
    }

    @Test func missingEntryIsNotUsed() {
        #expect(InputSourceShortcut(symbolicHotKeys: [:]) == nil)
        #expect(InputSourceShortcut(symbolicHotKeys: ["61": Self.hotKeys()["60"]!]) == nil)
    }

    /// Caps Lock and Fn switching are not symbolic hot keys; a bare key would type.
    @Test(arguments: [0, 8_388_608, 131_072 | 8_388_608])
    func shortcutWithoutASupportedModifierIsNotUsed(_ flags: Int) {
        #expect(InputSourceShortcut(symbolicHotKeys: Self.hotKeys(flags: flags)) == nil)
    }

    @Test(arguments: [-1, 128, 65_535])
    func unusableKeyCodeIsNotUsed(_ keyCode: Int) {
        #expect(InputSourceShortcut(symbolicHotKeys: Self.hotKeys(keyCode: keyCode)) == nil)
    }

    @Test func nonStandardTypeIsNotUsed() {
        #expect(InputSourceShortcut(symbolicHotKeys: Self.hotKeys(type: "modifier")) == nil)
    }

    @Test func modifierKeysArePressedAndReleasedInOrder() {
        let shortcut = InputSourceShortcut(keyCode: 49, flags: CGEventFlags([.maskControl, .maskCommand]).rawValue)
        // Control (59) then Command (55) down, released in reverse order.
        #expect(shortcut.modifierKeyCodes == [59, 55])
    }
}
