import KeyHueCore

/// 메뉴와 설정 창이 함께 쓰는 기능 상태와 동작. 두 곳이 같은 규칙으로 보이게 한 곳에 둔다.
@MainActor
protocol FeatureStatusActions: AnyObject {
    var escapeResetStatus: FeatureStatus { get }
    var textFocusResetStatus: FeatureStatus { get }
    var windowSwitchResetStatus: FeatureStatus { get }
    /// 창 전환 알림에 붙지 못한 맨 앞 앱 이름. `refreshFeatureStatuses()`가 먼저 연결을 갱신한다.
    var windowSwitchStalledApp: String? { get }
    var inputMethodRoutingStatus: FeatureStatus { get }
    var inputMethodInstallationStatus: InputMethodInstallationStatus { get }
    var isInputMethodOperationRunning: Bool { get }
    /// 상태를 갱신한 뒤 status getter를 읽는다. getter 자체는 부수 효과가 없어야 한다.
    func refreshFeatureStatuses()
    func installInputMethod()
    func uninstallInputMethod()
    func openInputSourceSettings()
    func setInputMethodRouting(_ enabled: Bool)
    func pauseInputMethodIntegration()
    func setResetOnEscape(_ enabled: Bool)
    func setOnWindowSwitch(_ behavior: SwitchBehavior)
    func openInputMonitoringSettings()
    func openAccessibilitySettings()
}

/// 메뉴에만 필요한 동작. Settings 전용 동작은 SettingsActions로 분리한다.
@MainActor
protocol StatusMenuActions: FeatureStatusActions {
    func showSettings()
    func showUpdates()
    /// 설정 창의 입력기 탭(ADR 0069).
    func showInputMethodSettings()
}

/// 설정 창에만 필요한 동작.
@MainActor
protocol SettingsActions: FeatureStatusActions {
    /// 잘못된 언어 경고(실험적, ADR 0041).
    var wrongLanguageStatus: FeatureStatus { get }
    /// 한글 음절 모델을 읽지 못해 경고가 동작하지 않는다(번들이 깨졌거나 번들 없이 실행).
    var isWrongLanguageModelMissing: Bool { get }
    var isLaunchAtLoginEnabled: Bool { get }
    /// macOS가 커서 옆에 띄우는 입력 소스 표시를 숨겼는지(macOS 설정, ADR 0034).
    var isSystemInputIndicatorHidden: Bool { get }
    /// macOS가 문장 첫 단어를 대문자로 바꾸는지(macOS 설정, ADR 0081).
    var isAutoCapitalizationOn: Bool { get }
    func setResetOnTextFocusLoss(_ enabled: Bool)
    func setWarnOnWrongLanguage(_ enabled: Bool)
    func setLaunchAtLogin(_ enabled: Bool)
    func setSystemInputIndicatorHidden(_ hidden: Bool)
    func forgetPerAppInputs()
    /// 로그 파일을 Finder에서 보여준다(ADR 0036).
    func showLogFile()
}
