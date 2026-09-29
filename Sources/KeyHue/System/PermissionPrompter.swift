import AppKit

/// 권한이 필요한 옵션을 켰을 때만 "왜 필요한지"를 먼저 설명한다. 앱 시작 시에는 아무것도 묻지 않는다.
@MainActor
enum PermissionPrompter {
    enum Permission {
        case inputMonitoring
        case accessibility

        var settingsURL: URL {
            switch self {
            case .inputMonitoring:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }
    }

    /// 설명 alert를 띄우고 사용자가 계속하기를 선택하면 true.
    static func explain(_ permission: Permission) -> Bool {
        let alert = NSAlert()
        switch permission {
        case .inputMonitoring:
            alert.messageText = "Allow Input Monitoring for ESC"
            alert.informativeText = """
            To switch to ABC when you press ESC, KeyHue needs Input Monitoring access.

            KeyHue only checks whether the pressed key is ESC. It never reads, stores, or sends what you type.

            After allowing KeyHue in System Settings › Privacy & Security › Input Monitoring, you may need to quit and reopen KeyHue.
            """
        case .accessibility:
            alert.messageText = "Allow Accessibility for Text Focus"
            alert.informativeText = """
            To switch to ABC when focus leaves a text field, KeyHue needs Accessibility access.

            KeyHue only reads the role of the focused element (for example, "text field"). It never reads the text inside it.

            This feature is experimental and may not work in every app.
            """
        }
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openSettings(_ permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
