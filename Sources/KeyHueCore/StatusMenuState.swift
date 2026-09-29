import Foundation

extension InputSourceInfo {
    /// 메뉴·설정 창에 표시할 이름. 이름이 비어 있으면 ID.
    public var displayName: String { localizedName.isEmpty ? id : localizedName }
}

/// 메뉴바 메뉴를 열 때 보여줄 상태(체크, 표시 여부, 활성 여부). 메뉴 그리기는 앱이 한다(ADR 0022).
public struct StatusMenuState: Sendable, Equatable {
    public var showStateBar: Bool
    public var resetOnAppSwitch: Bool
    public var escape: FeatureStatus
    public var textFocus: FeatureStatus
    public var windowSwitch: FeatureStatus
    /// "권한 허용…" 항목은 권한이 필요할 때만 보인다.
    public var showsEscapePermissionItem: Bool
    public var showsTextFocusPermissionItem: Bool
    public var showsWindowSwitchPermissionItem: Bool
    /// 자동 전환 문구에 들어갈 목표 입력 소스 이름("Switch to ABC on ESC").
    public var defaultSourceName: String
    /// 기본 입력 소스 서브메뉴에서 "자동" 항목에 보일 자동 선택 결과. 영문 배열이 없으면 nil.
    public var automaticSourceName: String?
    public var barPosition: BarPosition
    public var barHeight: Double
    public var barOpacity: Double
    public var displayPolicy: DisplayPolicy
    /// 막대 위치·두께·불투명도는 막대를 보일 때만 의미가 있다.
    public var barOptionsEnabled: Bool
    /// 디스플레이 정책은 막대나 HUD 중 하나라도 보일 때 의미가 있다.
    public var displaysEnabled: Bool
    public var showHUD: Bool
    public var rememberInputPerApp: Bool
    public var showsForgetItem: Bool
    public var tintMenuBarIcon: Bool
    public var showDockIcon: Bool
    public var launchAtLogin: Bool

    public static let fallbackSourceName = "ABC"

    public init(
        settings: KeyHueSettings,
        enabledSources: [InputSourceInfo],
        escape: FeatureStatus,
        textFocus: FeatureStatus,
        windowSwitch: FeatureStatus = .off,
        launchAtLogin: Bool
    ) {
        showStateBar = settings.showStateBar
        resetOnAppSwitch = settings.resetOnAppSwitch
        self.escape = escape
        self.textFocus = textFocus
        self.windowSwitch = windowSwitch
        showsEscapePermissionItem = escape == .needsPermission
        showsTextFocusPermissionItem = textFocus == .needsPermission
        showsWindowSwitchPermissionItem = windowSwitch == .needsPermission
        defaultSourceName = DefaultInputSourcePicker.pick(from: enabledSources, preferredID: settings.defaultSourceID)?.displayName
            ?? Self.fallbackSourceName
        automaticSourceName = DefaultInputSourcePicker.pick(from: enabledSources)?.displayName
        barPosition = settings.barPosition
        barHeight = settings.barHeight
        barOpacity = settings.barOpacity
        displayPolicy = settings.displayPolicy
        barOptionsEnabled = settings.showStateBar
        displaysEnabled = settings.showStateBar || settings.showHUD
        showHUD = settings.showHUD
        rememberInputPerApp = settings.rememberInputPerApp
        showsForgetItem = settings.rememberInputPerApp
        tintMenuBarIcon = settings.tintMenuBarIcon
        showDockIcon = settings.showDockIcon
        self.launchAtLogin = launchAtLogin
    }

    /// 불투명도 선택지 비교(부동소수 오차 허용).
    public func isSelectedOpacity(_ value: Double) -> Bool {
        abs(value - barOpacity) < 0.001
    }
}
