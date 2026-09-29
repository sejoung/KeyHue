import AppKit
import KeyHueCore

extension PermissionKind {
    /// 시스템 설정의 해당 개인정보 보호 화면.
    var settingsURL: URL {
        switch self {
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

/// 권한이 필요한 옵션을 켰을 때만 "왜 필요한지"를 먼저 설명한다.
/// 앱 시작 시에는 새 권한을 묻지 않고, 이미 켜 둔 옵션의 권한이 끊긴 경우에만 알린다(ADR 0021).
@MainActor
enum PermissionPrompter {
    enum MissingChoice {
        case allowAgain
        case turnOff
        case later
    }

    /// 켜 둔 기능이 권한 없이 멈춰 있을 때. 업데이트·재빌드로 서명이 바뀌면 이전 허용이 무효가 된다.
    static func explainMissing(_ permission: PermissionKind, feature: String) -> MissingChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let steps: String
        switch permission {
        case .inputMonitoring:
            alert.messageText = L("Input Monitoring Access Needed")
            steps = L("Choose Allow Again, then turn on KeyHue in System Settings › Privacy & Security › Input Monitoring.")
        case .accessibility:
            alert.messageText = L("Accessibility Access Needed")
            steps = L("Choose Allow Again, then turn on KeyHue in System Settings › Privacy & Security › Accessibility.")
        }
        alert.informativeText = [
            L("“%@” is on, but it isn't working because KeyHue doesn't have permission.", feature),
            L("This often happens after KeyHue is updated or rebuilt. macOS ties the permission to the app's signature, so the earlier approval no longer applies."),
            steps
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: L("Allow Again…"))
        alert.addButton(withTitle: L("Turn Off"))
        alert.addButton(withTitle: L("Later"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allowAgain
        case .alertSecondButtonReturn: return .turnOff
        default: return .later
        }
    }

    /// 이전 서명으로 남은 KeyHue 항목을 지운다. 그래야 시스템이 현재 빌드에 대해 새로 묻는다.
    /// KeyHue 자신의 항목만 지우며, 다른 앱의 권한에는 영향이 없다.
    static func resetStaleEntry(_ permission: PermissionKind) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", permission.tccService, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// 손쉬운 사용 권한을 쓰는 기능.
    enum AccessibilityFeature {
        case textFocus
        case windowSwitch
        case windowMemory
    }

    /// 설명 alert를 띄우고 사용자가 계속하기를 선택하면 true.
    static func explain(_ permission: PermissionKind, for feature: AccessibilityFeature = .textFocus) -> Bool {
        let alert = NSAlert()
        switch permission {
        case .inputMonitoring:
            alert.messageText = L("Allow Input Monitoring for ESC")
            alert.informativeText = [
                L("To switch to the default input source when you press ESC, KeyHue needs Input Monitoring access."),
                L("KeyHue only checks whether the pressed key is ESC. It never reads, stores, or sends what you type."),
                L("After allowing KeyHue in System Settings › Privacy & Security › Input Monitoring, you may need to quit and reopen KeyHue.")
            ].joined(separator: "\n\n")
        case .accessibility where feature == .windowSwitch || feature == .windowMemory:
            alert.messageText = L("Allow Accessibility for Window Switching")
            alert.informativeText = [
                feature == .windowMemory
                    ? L("To remember the input source for each window of an app, KeyHue needs Accessibility access.")
                    : L("To switch to the default input source when you move to another window of the same app, KeyHue needs Accessibility access."),
                L("KeyHue only notices that the app's main window changed. It never reads window titles or what's inside them.")
            ].joined(separator: "\n\n")
        case .accessibility:
            alert.messageText = L("Allow Accessibility for Text Focus")
            alert.informativeText = [
                L("To switch to the default input source when focus leaves a text field, KeyHue needs Accessibility access."),
                L("KeyHue only reads the role of the focused element (for example, \"text field\"). It never reads the text inside it."),
                L("This feature is experimental and may not work in every app.")
            ].joined(separator: "\n\n")
        }
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openSettings(_ permission: PermissionKind) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
