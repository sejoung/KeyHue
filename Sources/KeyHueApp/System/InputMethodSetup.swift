import AppKit
import KeyHueCore

/// 입력기 설치·제거 뒤의 안내, 모드 선택, 재실행과 입력 소스 설정 열기.
@MainActor
enum InputMethodSetup {
    /// Setup leaves ABC selected. Selecting English before Korean makes it the
    /// previous source, so the first ⌘Space toggles the two modes instead of going
    /// back to ABC and through routing (ADR 0071).
    static func selectHangulAfterSetup() -> Bool {
        _ = InputSourceController.select(sourceID: InputMethodIntegration.latinID)
        return InputSourceController.select(sourceID: InputMethodIntegration.hangulID)
    }

    static func promptToAddModes(openInputSourceSettings: () -> Void) {
        let alert = NSAlert()
        alert.messageText = L("Input Method Installed")
        alert.informativeText = [
            L("Installation is complete. In System Settings → Keyboard → Text Input → Edit → +, add KeyHue Korean and English. Integration starts when both modes are enabled; you do not need to turn this option on again."),
            // System Settings sometimes leaves the first languages' lists empty until another language is chosen.
            L("If the Korean or English list is empty, choose another language once and then choose Korean or English again.")
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: L("Open Input Source Settings"))
        alert.addButton(withTitle: L("Later"))
        if alert.runModal() == .alertFirstButtonReturn { openInputSourceSettings() }
    }

    enum ModesInUseChoice: Equatable {
        case openInputSourceSettings, removeAnyway, later
    }

    /// ADR 0087: the modes are removed in System Settings, which macOS 26 can fail to
    /// save; a mode it keeps is then listed nowhere and only "Remove Anyway" gets past it.
    static func modesInUseAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Input Method Operation Failed")
        alert.informativeText = [
            InputMethodManagementError.inputSourcesInUse.localizedDescription,
            L("If System Settings no longer lists them, macOS kept them by mistake. Choose Remove Anyway: KeyHue turns off what it can and removes the input method. What macOS keeps does nothing without it.")
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: L("Open Input Source Settings"))
        alert.addButton(withTitle: L("Remove Anyway"))
        alert.addButton(withTitle: L("Later"))
        return alert
    }

    static func explainModesInUse() -> ModesInUseChoice {
        NSApp.activate(ignoringOtherApps: true)
        switch modesInUseAlert().runModal() {
        case .alertFirstButtonReturn: return .openInputSourceSettings
        case .alertSecondButtonReturn: return .removeAnyway
        default: return .later
        }
    }

    static func showPauseFailed() {
        let alert = NSAlert()
        alert.messageText = L("Integration Paused")
        alert.informativeText = L("ABC could not be selected. Choose an available input source from the macOS input menu.")
        alert.runModal()
    }

    static func relaunch(finishSetup: Bool, reason: String = "refresh input source registration") throws {
        guard let executable = Bundle.main.executableURL else { throw InputMethodManagementError.systemFailure }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = WorkerCommand.relaunchArguments(parentPID: ProcessInfo.processInfo.processIdentifier, finishSetup: finishSetup)
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        _ = UserDefaults.standard.synchronize()
        try helper.run()
        Log.app.notice("relaunching KeyHue to \(reason)")
        NSApplication.shared.terminate(nil)
    }

    /// - Parameter installedBundle: where the input method is installed.
    static func openInputSourceSettings(installedBundle: URL) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        // A System Settings window opened before the input method was installed keeps
        // its old input source catalog: KeyHue's modes are missing from the + list until
        // something else changes it (ADR 0076). Open a fresh one.
        // The Input Methods folder changes when the bundle is moved in; the copied bundle
        // keeps its build date.
        let folder = installedBundle.deletingLastPathComponent()
        let installed = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stale = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").filter {
            guard let installed, let launched = $0.launchDate else { return false }
            return launched < installed
        }
        guard !stale.isEmpty else { NSWorkspace.shared.open(url); return }
        Log.app.notice("reopening System Settings opened before the input method was installed")
        stale.forEach { $0.forceTerminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.open(url)
        }
    }
}
