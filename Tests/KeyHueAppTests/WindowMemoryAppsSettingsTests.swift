import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

private struct PickedApps: SettingsDialogs {
    let apps: [String]
    func confirmPublicReport(summary: String) -> Bool { false }
    func chooseApps() -> [String] { apps }
}

/// ADR 0089: the settings window adds and removes apps through the actions, which ask for Accessibility first.
@MainActor
@Suite("Apps that remember each window: settings")
struct WindowMemoryAppsSettingsTests {
    private func makeModel(_ actions: SettingsActions, store: SettingsStore, picked: [String] = []) -> SettingsModel {
        let model = SettingsModel(
            store: store, actions: actions,
            updates: UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), scheduler: FakeScheduler()) {
                throw GitHubReleaseFetcher.Failure.invalidResponse
            },
            dialogs: PickedApps(apps: picked)
        ) { [.abc, .korean2Set] }
        model.reload()
        return model
    }

    @Test func addingAndRemovingGoThroughTheActions() {
        let actions = AppEdgeDecliningActions()
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(actions, store: store, picked: ["com.mitchellh.ghostty", "com.apple.Terminal"])
        model.chooseWindowMemoryApps()
        model.removeWindowMemoryApp("com.apple.Terminal")
        #expect(actions.calls == ["eachWindow:true:com.mitchellh.ghostty,com.apple.Terminal", "eachWindow:false:com.apple.Terminal"])
        #expect(store.settings.windowMemoryApps.isEmpty) // The declining actions changed nothing.
    }

    @Test func theNoticeSaysWhyTheListIsNotApplied() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(AppEdgeDecliningActions(), store: store)
        #expect(model.windowMemoryAppsNotice != nil)                  // Apps are kept as they are.
        store.update { $0.onAppSwitch = .restoreLast }
        #expect(model.windowMemoryAppsNotice == nil)
        store.update { $0.onWindowSwitch = .restoreLast }
        #expect(model.windowMemoryAppsNotice != nil)                  // Every window is already restored.
    }

    @Test func turningAccessibilityOffNamesTheList() {
        var settings = KeyHueSettings()
        settings.onAppSwitch = .restoreLast
        settings.windowMemoryApps = ["com.mitchellh.ghostty"]
        let list = PermissionFlow.featureText(for: .accessibility, settings: settings, defaultName: "ABC")
        #expect(list.contains("Apps That Remember Each Window"))
        settings.onWindowSwitch = .switchToDefault
        settings.resetOnTextFocusLoss = true
        #expect(PermissionFlow.featureText(for: .accessibility, settings: settings, defaultName: "ABC")
            .components(separatedBy: "”, “").count == 3)
        settings.onAppSwitch = .keep                                   // The list no longer applies.
        #expect(PermissionFlow.featureText(for: .accessibility, settings: settings, defaultName: "ABC")
            .components(separatedBy: "”, “").count == 2)
    }
}
