import AppKit
import KeyHueCore

/// 메뉴와 설정 창의 요청을 앱 동작으로 옮기고, 기능 상태를 알려 준다.
/// 권한이 필요한 기능은 켜기 전에 안내한다(`PermissionFlow`).
@MainActor
final class AppActions: StatusMenuActions, SettingsActions {
    private let settingsStore: SettingsStore
    private let permissions: PermissionFlow
    private let monitors: FeatureMonitors
    private let switching: InputSwitching
    private let inputSourceMonitor: InputSourceMonitor
    private let inputMethodManager: InputMethodManager
    private let inputMethodLifecycle: InputMethodLifecycleCoordinator
    private let settingsWindow: () -> SettingsWindowController?

    init(settingsStore: SettingsStore,
         permissions: PermissionFlow,
         monitors: FeatureMonitors,
         switching: InputSwitching,
         inputSourceMonitor: InputSourceMonitor,
         inputMethodManager: InputMethodManager,
         inputMethodLifecycle: InputMethodLifecycleCoordinator,
         settingsWindow: @escaping () -> SettingsWindowController?) {
        self.settingsStore = settingsStore
        self.permissions = permissions
        self.monitors = monitors
        self.switching = switching
        self.inputSourceMonitor = inputSourceMonitor
        self.inputMethodManager = inputMethodManager
        self.inputMethodLifecycle = inputMethodLifecycle
        self.settingsWindow = settingsWindow
    }

    // MARK: - Status

    func refreshFeatureStatuses() { monitors.update() }

    var escapeResetStatus: FeatureStatus { monitors.escapeResetStatus }
    var textFocusResetStatus: FeatureStatus { monitors.textFocusResetStatus }
    var windowSwitchResetStatus: FeatureStatus { monitors.windowSwitchResetStatus }
    var windowSwitchStalledApp: String? { monitors.windowSwitchStalledApp }
    var wrongLanguageStatus: FeatureStatus { monitors.wrongLanguageStatus }
    var isWrongLanguageModelMissing: Bool { monitors.isWrongLanguageModelMissing }
    var inputMethodRoutingStatus: FeatureStatus { monitors.inputMethodRoutingStatus }
    var inputMethodInstallationStatus: InputMethodInstallationStatus { inputMethodManager.status }
    var isInputMethodOperationRunning: Bool { inputMethodLifecycle.isRunning }
    var isLaunchAtLoginEnabled: Bool { LoginItemController.isEnabled }
    var isSystemInputIndicatorHidden: Bool { SystemInputIndicator().isHidden }

    // MARK: - Input method

    func installInputMethod() {
        // The lifecycle also ignores a second request; checking first skips the permission prompt.
        guard !inputMethodLifecycle.isRunning else { return }
        // Choosing the integrated input method also chooses the two-mode setup.
        // Explain its optional system permission before changing files or sources.
        guard permissions.allowEnabling(.inputMonitoring(.inputMethodRouting)) else { return }
        inputMethodLifecycle.manage(removing: false)
    }

    func uninstallInputMethod() {
        inputMethodLifecycle.manage(removing: true)
    }

    func openInputSourceSettings() {
        InputMethodSetup.openInputSourceSettings(installedBundle: inputMethodManager.destination)
    }

    func setInputMethodRouting(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.inputMonitoring(.inputMethodRouting)) else { return }
        settingsStore.update { $0.routeInputMethodPair = enabled }
    }

    func pauseInputMethodIntegration() {
        // Change settings first so subsequent notifications cannot redirect ABC.
        settingsStore.update { $0.integrateInputMethod = false }
        switching.autoReset.cancelPendingWork()
        switching.router.reset(current: nil)
        let ok = InputMethodSourcePreferences.shared.isSupported
            ? InputSourceController.selectFresh(sourceID: InputMethodIntegration.abcID)
            : InputSourceController.select(sourceID: InputMethodIntegration.abcID)
        switching.router.reset(current: InputSourceController.current())
        inputSourceMonitor.refresh()
        Log.state.notice("input method integration paused; ABC selection \(ok ? "ok" : "FAILED")")
        if !ok {
            let alert = NSAlert()
            alert.messageText = L("Integration Paused")
            alert.informativeText = L("ABC could not be selected. Choose an available input source from the macOS input menu.")
            alert.runModal()
        }
    }

    // MARK: - Features that need a permission

    func setResetOnEscape(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.inputMonitoring(.escape)) else { return }
        settingsStore.update { $0.resetOnEscape = enabled }
    }

    func setWarnOnWrongLanguage(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.inputMonitoring(.wrongLanguage)) else { return }
        settingsStore.update { $0.warnOnWrongLanguage = enabled }
    }

    func setOnWindowSwitch(_ behavior: SwitchBehavior) {
        let feature: PermissionPrompter.AccessibilityFeature = behavior == .restoreLast ? .windowMemory : .windowSwitch
        guard behavior == .keep || permissions.allowEnabling(.accessibility(feature)) else { return }
        settingsStore.update { $0.onWindowSwitch = behavior }
    }

    func setResetOnTextFocusLoss(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.accessibility(.textFocus)) else { return }
        settingsStore.update { $0.resetOnTextFocusLoss = enabled }
    }

    func openInputMonitoringSettings() {
        permissions.requestAgain(.inputMonitoring)
    }

    func openAccessibilitySettings() {
        permissions.requestAgain(.accessibility)
    }

    // MARK: - System settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            if enabled, LoginItemController.requiresApproval {
                LoginItemController.openSystemSettings()
            }
        } catch {
            PermissionPrompter.showError(L("Couldn't change Launch at Login"), error)
        }
    }

    func setSystemInputIndicatorHidden(_ hidden: Bool) {
        SystemInputIndicator().setHidden(hidden)
        Log.app.notice("macOS input source indicator \(hidden ? "hidden" : "shown")")
    }

    func forgetPerAppInputs() {
        switching.autoReset.forgetRememberedInputs()
    }

    // MARK: - Windows

    func showUpdates() { settingsWindow()?.showUpdates() }
    func showSettings() { settingsWindow()?.show() }
    func showInputMethodSettings() { settingsWindow()?.showInputMethod() }

    /// 문제를 알릴 때 첨부할 로그 파일을 Finder에서 보여준다(ADR 0036). 아직 없으면 폴더를 연다.
    func showLogFile() {
        Log.file?.flush()
        let file = Log.fileURL
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}
