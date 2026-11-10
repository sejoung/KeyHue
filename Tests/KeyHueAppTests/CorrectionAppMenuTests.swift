import AppKit
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
@Suite("Word fixing in the current app", .appKit)
struct CorrectionAppMenuTests {
    private let editor = FrontApp(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA")
    private let otherApp = "com.apple.Notes"
    private let action = NSSelectorFromString("toggleCorrectionApp")

    private func state(_ settings: KeyHueSettings, app: FrontApp?) -> StatusMenuState {
        StatusMenuState(settings: settings, enabledSources: [.abc], escape: .off, textFocus: .off, frontApp: app)
    }

    @Test(arguments: [CorrectionMode.manual, .automatic])
    func theMenuExcludesAndRestoresOnlyTheAppItNamed(_ mode: CorrectionMode) throws {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.integrateInputMethod = true
            $0.inputMethodCorrection = mode
            $0.correctionExcludedApps = [otherApp]
        }
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        let controller = StatusBarController(settingsStore: store, stateStore: InputStateStore(), actions: actions,
                                             updates: UpdateChecker(defaults: makeTestDefaults()), displaySettings: { store.settings })
        controller.apply(state(store.settings, app: editor))
        let item = try #require(controller.menu.items.first { $0.action == action })
        #expect(!item.isHidden && item.isEnabled)
        #expect(item.title.contains(editor.name))
        #expect(item.state == .off)

        // The action must use the app captured in the menu, not query the OS again.
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(NSApp.sendAction(action, to: item.target, from: item)) // No duplicate if dispatched twice.
        #expect(model.settings.correctionExcludedApps == [otherApp, editor.bundleID])
        #expect(SettingsStore(defaults: defaults).settings.correctionExcludedApps == [otherApp, editor.bundleID])
        #expect(store.settings.inputMethodCorrection == mode)
        #expect(store.settings.integrateInputMethod)

        controller.buildMenu()
        controller.apply(state(store.settings, app: editor))
        #expect(controller.menu.items.filter { $0.action == action }.count == 1)
        #expect(item.state == .on)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(model.settings.correctionExcludedApps == [otherApp])
        #expect(SettingsStore(defaults: defaults).settings.correctionExcludedApps == [otherApp])
        #expect(store.settings.inputMethodCorrection == mode)
        #expect(actions.calls.isEmpty) // No permission prompt is needed.
    }

    @Test func settingsChangesAreReflectedWhenTheMenuOpensAgain() throws {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.integrateInputMethod = true }
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        let controller = StatusBarController(settingsStore: store, stateStore: InputStateStore(), actions: actions,
                                             updates: UpdateChecker(defaults: makeTestDefaults()), displaySettings: { store.settings })
        model.addExcludedApps([editor.bundleID])
        controller.apply(state(store.settings, app: editor))
        let item = try #require(controller.menu.items.first { $0.action == action })
        #expect(item.state == .on)
        model.removeExcludedApp(editor.bundleID)
        controller.apply(state(store.settings, app: editor))
        #expect(item.state == .off)

        let nextApp = FrontApp(bundleID: otherApp, name: "Notes")
        controller.apply(state(store.settings, app: nextApp))
        #expect(item.title.contains(nextApp.name))
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(model.settings.correctionExcludedApps == [otherApp])
    }

    @Test func unavailableWordFixingHidesTheActionAndClearsItsTarget() throws {
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = RecordingActions()
        let controller = StatusBarController(settingsStore: store, stateStore: InputStateStore(), actions: actions,
                                             updates: UpdateChecker(defaults: makeTestDefaults()), displaySettings: { store.settings })
        let item = try #require(controller.menu.items.first { $0.action == action })
        for (integrate, mode, app) in [(false, CorrectionMode.manual, editor as FrontApp?),
                                       (true, .off, editor), (true, .manual, nil)] {
            store.update { $0.integrateInputMethod = true; $0.inputMethodCorrection = .manual }
            controller.apply(state(store.settings, app: editor))
            #expect(!item.isHidden)
            store.update { $0.integrateInputMethod = integrate; $0.inputMethodCorrection = mode }
            controller.apply(state(store.settings, app: app))
            #expect(item.isHidden)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            #expect(store.settings.correctionExcludedApps.isEmpty)
        }
    }
}
