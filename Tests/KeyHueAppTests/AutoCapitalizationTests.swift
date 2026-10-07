import CoreFoundation
import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// ADR 0081: macOS capitalizes the first word of a sentence, so the fix shortcut can
/// read a capital the user did not type. KeyHue reads the setting and recommends
/// turning it off; it never changes it.
@MainActor
@Suite("Automatic capitalization notice")
struct AutoCapitalizationTests {
    /// A temporary domain instead of the real global one (see SystemInputIndicatorTests).
    private func withDomain(_ body: (SystemAutoCapitalization, CFString) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueTests-capitalization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file.appendingPathExtension("plist")) }
        let domain = file.path as CFString
        body(SystemAutoCapitalization(domain: domain), domain)
        set(nil, domain)
    }

    private func set(_ value: CFPropertyList?, _ domain: CFString) {
        CFPreferencesSetValue(SystemAutoCapitalization.key as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    @Test func usesTheGlobalMacOSKey() {
        #expect(SystemAutoCapitalization.key == "NSAutomaticCapitalizationEnabled")
    }

    @Test func onByDefaultAndOffOnlyWhenTurnedOff() {
        withDomain { setting, domain in
            #expect(setting.isOn) // macOS turns it on until the user turns it off
            set(0 as NSNumber, domain)
            #expect(!setting.isOn)
            set(kCFBooleanFalse, domain)
            #expect(!setting.isOn)
            set(1 as NSNumber, domain)
            #expect(setting.isOn)
        }
    }

    @Test func noticeShowsOnlyWhileWordFixingIsInUse() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = RecordingActions()
        actions.isAutoCapitalizationOn = true
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        model.reload()
        #expect(!model.showsAutoCapitalizationNotice) // the input method is not in use
        store.update { $0.integrateInputMethod = true }
        #expect(model.showsAutoCapitalizationNotice)
        store.update { $0.inputMethodCorrection = .off }
        #expect(!model.showsAutoCapitalizationNotice)
        store.update { $0.inputMethodCorrection = .automatic }
        #expect(model.showsAutoCapitalizationNotice)
        // Turned off in System Settings: read again when the window is shown.
        actions.isAutoCapitalizationOn = false
        model.reload()
        #expect(!model.showsAutoCapitalizationNotice)
        model.openKeyboardSettings()
        #expect(actions.calls == ["openInputSources"])
    }
}
