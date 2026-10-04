import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// ADR 0064: the correction mode and the apps that are never corrected.
@MainActor
@Suite("Correction settings model")
struct CorrectionSettingsModelTests {
    private func makeModel(_ store: SettingsStore = SettingsStore(defaults: makeTestDefaults())) -> SettingsModel {
        let model = SettingsModel(
            store: store, actions: AppEdgeDecliningActions(),
            updates: UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), scheduler: FakeScheduler()) {
                throw GitHubReleaseFetcher.Failure.invalidResponse
            }
        ) { [.abc, .korean2Set] }
        model.reload()
        return model
    }

    @Test func theModeIsStored() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(store)
        model.binding(\.inputMethodCorrection).wrappedValue = .automatic
        #expect(store.settings.inputMethodCorrection == .automatic)
    }

    /// The input method follows the utility's setting only while it is in use.
    @Test func theModeIsChosenOnlyWhileTheInputMethodIsUsed() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(store)
        #expect(!model.isCorrectionEditable)
        store.update { $0.integrateInputMethod = true }
        model.reload()
        #expect(model.isCorrectionEditable)
    }

    @Test func addingAppsKeepsOrderAndSkipsDuplicatesAndBlanks() {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.correctionExcludedApps = ["com.apple.Terminal"] }
        let model = makeModel(store)
        model.addExcludedApps(["com.example.Editor", "com.apple.Terminal", "", "com.example.Editor"])
        #expect(store.settings.correctionExcludedApps == ["com.apple.Terminal", "com.example.Editor"])
    }

    @Test func removingAndRestoringApps() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(store)
        model.removeExcludedApp("com.apple.Terminal")
        #expect(!store.settings.correctionExcludedApps.contains("com.apple.Terminal"))
        #expect(!model.excludedAppsAreDefault)
        model.restoreDefaultExcludedApps()
        #expect(store.settings.correctionExcludedApps == InputMethodCorrection.defaultExcludedApps)
        #expect(model.excludedAppsAreDefault)
    }

    /// Apps that are not installed are still listed by their bundle ID.
    @Test func uninstalledAppsAreShownByBundleID() {
        #expect(makeModel().appName(for: "com.example.NotInstalled") == "com.example.NotInstalled")
    }

    @Test func installedAppsAreShownByName() {
        #expect(makeModel().appName(for: "com.apple.finder") == "Finder")
    }
}
