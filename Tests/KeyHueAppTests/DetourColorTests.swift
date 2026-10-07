import KeyHueCore
import Testing
@testable import KeyHueApp

/// ADR 0082: while both KeyHue modes are integrated, ABC and the system 2-Set Korean
/// are detours and shown gray, also in the settings window's color list.
@MainActor
@Suite("Detour colors")
struct DetourColorTests {
    @Test func settingsShowDetoursGrayOnlyWhileIntegrated() {
        let hangul = InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false)
        let latin = InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = SettingsModel(store: store, actions: RecordingActions()) { [.abc, .korean2Set, hangul, latin] }
        model.reload()
        #expect(model.displaySettings.color(for: .abc) == model.settings.color(for: .abc)) // not integrated
        store.update { $0.integrateInputMethod = true }
        #expect(model.displaySettings.color(for: .abc) == InputMethodIntegration.detourColor)
        #expect(model.displaySettings.color(for: .korean2Set) == InputMethodIntegration.detourColor)
        #expect(model.displaySettings.color(for: latin) == model.settings.color(for: latin))
        #expect(model.settings.sourceColors.isEmpty) // nothing is saved
    }
}
