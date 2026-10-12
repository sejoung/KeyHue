import AppKit
import KeyHueCore
import Testing
@testable import KeyHueApp

extension RecordingActions: StatusMenuActions {
    func showSettings() { calls.append("settings") }
    func showUpdates() { calls.append("updates") }
    func showInputMethodSettings() { calls.append("inputMethodSettings") }
}

@MainActor
@Suite("Status bar menu")
struct StatusBarControllerTests {
    /// Changing the app language rebuilds the menu. Items reused from the input
    /// method submenu must leave the old submenu first, or NSMenu throws.
    @Test func rebuildingTheMenuForANewLanguageKeepsEveryItem() {
        let actions = RecordingActions()
        let store = SettingsStore(defaults: makeTestDefaults())
        let controller = StatusBarController(settingsStore: store, stateStore: InputStateStore(), actions: actions,
                                             updates: UpdateChecker(defaults: makeTestDefaults()), displaySettings: { store.settings })
        let titles = controller.menu.items.map(\.title)
        let submenu = controller.menu.items.compactMap(\.submenu).map { $0.items.count }
        controller.buildMenu()
        controller.buildMenu()
        #expect(controller.menu.items.map(\.title) == titles)
        #expect(controller.menu.items.compactMap(\.submenu).map { $0.items.count } == submenu)
    }
}
