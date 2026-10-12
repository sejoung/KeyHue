import AppKit
import KeyHueCore

/// 설정에 맞춰 키보드·AX 감시를 켜고 끄고, 그 감시에 기대는 기능이 실제로 동작하는지 알려 준다.
///
/// 상태 getter는 부수 효과가 없다. 메뉴·설정 창은 `update()`로 감시를 맞춘 뒤 읽는다(ADR 0079).
@MainActor
final class FeatureMonitors {
    let keyboard: KeyboardMonitor
    let focus: AccessibilityFocusMonitor
    let wrongLanguage: WrongLanguageMonitor

    private let settings: @MainActor () -> KeyHueSettings
    private let frontApp: @MainActor () -> AppFocusMonitor.ActiveApp?

    /// The monitors are injected so a caller can give them its own scheduler or model.
    init(settings: @escaping @MainActor () -> KeyHueSettings,
         frontApp: @escaping @MainActor () -> AppFocusMonitor.ActiveApp?,
         keyboard: KeyboardMonitor = KeyboardMonitor(),
         focus: AccessibilityFocusMonitor = AccessibilityFocusMonitor(),
         wrongLanguage: WrongLanguageMonitor = WrongLanguageMonitor()) {
        self.settings = settings
        self.frontApp = frontApp
        self.keyboard = keyboard
        self.focus = focus
        self.wrongLanguage = wrongLanguage
    }

    func update() {
        updateKeyboard()
        updateFocus()
    }

    func updateKeyboard() {
        let settings = settings()
        wrongLanguage.setEnabled(settings.warnOnWrongLanguage)
        if settings.watchesKeyboard {
            keyboard.start(observeMouse: settings.watchesMouseClicks)
        } else {
            keyboard.stop()
        }
    }

    func updateFocus() {
        // 켜진 옵션에 필요한 알림·조회만 한다(텍스트 필드가 꺼져 있으면 포커스 변경은 구독하지 않는다).
        let use = settings().accessibilityUse
        if !use.isEmpty, let pid = frontApp()?.pid {
            focus.attach(to: pid, for: use)
        } else {
            focus.detach()
        }
    }

    func stop() {
        keyboard.stop()
        focus.detach()
    }

    /// The tap can outlive a revoked Input Monitoring permission. The tap check comes
    /// first so the TCC preflight runs only while the monitor is on.
    var isKeyboardWorking: Bool {
        keyboard.isRunning && SystemPermissions.has(.inputMonitoring)
    }

    // MARK: - Feature status

    var escapeResetStatus: FeatureStatus {
        keyboardStatus(isEnabled: settings().resetOnEscape)
    }

    var wrongLanguageStatus: FeatureStatus {
        keyboardStatus(isEnabled: settings().warnOnWrongLanguage)
    }

    var isWrongLanguageModelMissing: Bool {
        settings().warnOnWrongLanguage && wrongLanguage.isModelMissing
    }

    var inputMethodRoutingStatus: FeatureStatus {
        let settings = settings()
        return keyboardStatus(isEnabled: settings.routesInputMethodPair
            && InputMethodIntegration.isAvailable(in: InputSourceController.enabledSources()))
    }

    var textFocusResetStatus: FeatureStatus {
        accessibilityStatus(isEnabled: settings().resetOnTextFocusLoss)
    }

    var windowSwitchResetStatus: FeatureStatus {
        accessibilityStatus(isEnabled: settings().watchesWindowSwitches)
    }

    /// 창 전환 알림을 받지 못하는 맨 앞 앱 이름(ADR 0038).
    var windowSwitchStalledApp: String? {
        guard settings().watchesWindowSwitches,
              let pid = focus.stalledPID,
              pid == frontApp()?.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? frontApp()?.bundleID
    }

    private func keyboardStatus(isEnabled: Bool) -> FeatureStatus {
        PermissionPolicy.status(isEnabled: isEnabled, isWorking: isEnabled && isKeyboardWorking)
    }

    private func accessibilityStatus(isEnabled: Bool) -> FeatureStatus {
        PermissionPolicy.status(isEnabled: isEnabled, isWorking: isEnabled && SystemPermissions.has(.accessibility))
    }
}
