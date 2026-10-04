import Foundation
import Testing
@testable import KeyHueCore

/// ADR 0068: the user asks for a fix with a shortcut they choose in Settings.
/// The input method receives the key itself, so the shortcut must be a key the
/// input method can see and that never types text.
@MainActor
@Suite("Correction shortcut")
struct CorrectionShortcutTests {
    @Test func optionReturnIsTheDefault() {
        #expect(CorrectionShortcut.default == CorrectionShortcut(keyCode: 36, modifiers: .option))
        #expect(KeyHueSettings().correctionShortcut == .default)
        #expect(CorrectionShortcut.default.displayName == "⌥↩")
    }

    @Test func itIsStoredAsText() {
        let shortcut = CorrectionShortcut(keyCode: 49, modifiers: [.control, .shift])
        #expect(shortcut.rawValue == "control+shift+49")
        #expect(CorrectionShortcut(rawValue: "control+shift+49") == shortcut)
        #expect(CorrectionShortcut(rawValue: "option+36") == .default)
    }

    @Test(arguments: ["", "36", "option+", "option+x", "hyper+36", "option+200", "option+-1"])
    func malformedTextIsRejected(_ raw: String) {
        #expect(CorrectionShortcut(rawValue: raw) == nil)
    }

    /// ⌥ or ⌃ with a key, or ⇧ with Space or Return. ⌘ is the app's menu keys and
    /// often never reaches the input method; a plain or ⇧ letter types text; ⌃Space
    /// and ⌃⌥Space are the system's input source shortcuts.
    @Test func onlyKeysTheInputMethodCanOwnAreAllowed() {
        #expect(CorrectionShortcut(keyCode: 36, modifiers: .option).isAllowed)
        #expect(CorrectionShortcut(keyCode: 49, modifiers: .option).isAllowed)
        #expect(CorrectionShortcut(keyCode: 49, modifiers: .shift).isAllowed)
        #expect(CorrectionShortcut(keyCode: 36, modifiers: .shift).isAllowed)
        #expect(CorrectionShortcut(keyCode: 17, modifiers: [.control, .option]).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 36, modifiers: []).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 0, modifiers: .shift).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 36, modifiers: .command).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 36, modifiers: [.command, .option]).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 49, modifiers: .control).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 49, modifiers: [.control, .option]).isAllowed)
        #expect(!CorrectionShortcut(keyCode: 58, modifiers: .option).isAllowed) // a modifier key itself
    }

    @Test func displayNamesUseTheUsualSymbols() {
        #expect(CorrectionShortcut(keyCode: 49, modifiers: [.control, .option, .shift]).displayName == "⌃⌥⇧Space")
        #expect(CorrectionShortcut(keyCode: 48, modifiers: .option).displayName == "⌥⇥")
        #expect(CorrectionShortcut(keyCode: 17, modifiers: .control).displayName == "⌃T")
    }

    @Test func aKeyMatchesOnlyWithExactlyItsModifiers() {
        let shortcut = CorrectionShortcut.default
        #expect(shortcut.matches(keyCode: 36, modifiers: .option))
        #expect(!shortcut.matches(keyCode: 36, modifiers: [.option, .shift]))
        #expect(!shortcut.matches(keyCode: 36, modifiers: []))
        #expect(!shortcut.matches(keyCode: 76, modifiers: .option))
    }

    // MARK: settings

    @Test func theShortcutSurvivesAReloadAndTheDefaultIsNotStored() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.correctionShortcut = CorrectionShortcut(keyCode: 49, modifiers: .shift) }
        #expect(SettingsStore(defaults: defaults).settings.correctionShortcut == CorrectionShortcut(keyCode: 49, modifiers: .shift))
        store.update { $0.correctionShortcut = .default }
        #expect(defaults.object(forKey: InputMethodCorrection.Key.shortcut) == nil)
    }

    @Test func aMalformedOrDisallowedShortcutFallsBack() {
        for raw: Any in ["option+x", "command+36", 7] {
            let defaults = makeTestDefaults()
            defaults.set(raw, forKey: InputMethodCorrection.Key.shortcut)
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.correctionShortcut == .default)
            #expect(store.ignoredKeys.contains(InputMethodCorrection.Key.shortcut))
            #expect(InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: nil, recordUndone: nil,
                                               shortcut: raw).shortcut == .default)
        }
    }

    @Test func theInputMethodReadsTheShortcut() {
        #expect(InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: nil, recordUndone: nil,
                                           shortcut: "shift+49").shortcut == CorrectionShortcut(keyCode: 49, modifiers: .shift))
        #expect(InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: nil, recordUndone: nil).shortcut == .default)
    }
}
