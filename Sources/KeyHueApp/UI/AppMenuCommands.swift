import AppKit

/// The commands both menus offer: Settings, About and Check for Updates. The menu
/// bar menu (`StatusBarController`) and the app menu (`MainMenu`) target this object.
@MainActor
final class AppMenuCommands: NSObject, NSUserInterfaceValidations {
    private let updates: UpdateChecker
    private weak var actions: StatusMenuActions?

    init(updates: UpdateChecker, actions: StatusMenuActions) {
        self.updates = updates
        self.actions = actions
    }

    @objc func showSettings() {
        actions?.showSettings()
    }

    @objc func showAbout() {
        AboutPanel.show()
    }

    /// Opens a newer release, or checks for one.
    @objc func checkForUpdates() {
        if let url = updates.releaseURL {
            NSWorkspace.shared.open(url)
        } else {
            actions?.showUpdates()
            Task { await updates.checkNow() }
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action != #selector(checkForUpdates) || !updates.state.isChecking
    }
}
