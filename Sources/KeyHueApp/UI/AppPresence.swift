import AppKit
import KeyHueCore

/// KeyHue가 화면에 어떻게 있는지: Dock 표시, Dock에 보일 때의 앱 메뉴, 한 번에 하나만 실행.
@MainActor
enum AppPresence {
    /// Dock 표시(regular) ↔ 메뉴바 전용(accessory). 재시작 없이 바로 바뀐다.
    /// 설정 창이 닫힐 때는 창이 아직 보이는 상태로 불리므로, 열림 여부를 직접 받는다.
    static func applyDockIconPolicy(settings: KeyHueSettings, settingsWindowOpen open: Bool) {
        let policy: NSApplication.ActivationPolicy = settings.showsDockIcon(settingsWindowOpen: open) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if open {
            // 정책이 바뀌면 앱이 비활성화되어 열려 있던 설정 창이 뒤로 숨는다.
            NSApp.activate(ignoringOtherApps: true)
        } else if policy == .accessory {
            // 설정 창을 닫아 메뉴바 전용으로 돌아간다. 창 없는 KeyHue에 포커스가 남지 않게 원래 앱에 돌려준다(ADR 0038).
            NSApp.hide(nil)
        }
    }

    /// Dock에 보일 때 화면 상단에 나오는 앱 메뉴.
    static func installMainMenu(statusBar: StatusBarController?, updates: UpdateChecker?) {
        guard let statusBar else { return }
        NSApp.mainMenu = MainMenu.make(
            target: statusBar,
            showSettings: #selector(StatusBarController.showSettings),
            showAbout: #selector(StatusBarController.showAbout),
            updates: updates,
            checkUpdates: #selector(StatusBarController.updateAction)
        )
    }

    static func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != .current }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }
}
