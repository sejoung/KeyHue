import AppKit

/// The settings window's own dialogs. The model asks; tests answer without a window.
@MainActor
protocol SettingsDialogs {
    /// Shows what will be published; true when the user agrees to open it.
    func confirmPublicReport(summary: String) -> Bool
    /// Apps the user picked, as bundle IDs.
    func chooseApps() -> [String]
}

@MainActor
struct SystemSettingsDialogs: SettingsDialogs {
    func confirmPublicReport(summary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Open a Public GitHub Issue?")
        alert.informativeText = L("KeyHue doesn't send anything itself. Your browser opens a prefilled issue that anyone can read; review and edit it before you submit:") + "\n\n" + summary
        alert.addButton(withTitle: L("Open in Browser"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func chooseApps() -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
