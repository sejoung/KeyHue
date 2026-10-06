import Foundation

extension InputSourceInfo {
    /// 메뉴·설정 창에 표시할 이름. 이름이 비어 있으면 ID.
    public var displayName: String { localizedName.isEmpty ? id : localizedName }
}

/// 메뉴바 메뉴를 열 때 보여줄 상태(체크, 표시 여부, 활성 여부). 메뉴 그리기는 앱이 한다(ADR 0022).
/// 메뉴에는 자주 바꾸는 것만 두고, 막대 모양·색·Dock·로그인 시 실행은 설정 창에서 바꾼다(ADR 0038).
public struct StatusMenuState: Sendable, Equatable {
    public var showStateBar: Bool
    public var onAppSwitch: SwitchBehavior
    public var onWindowSwitch: SwitchBehavior
    public var escape: FeatureStatus
    /// 창 전환 옵션(그대로 두기가 아닐 때)의 권한 상태.
    public var windowSwitch: FeatureStatus
    /// "권한 허용…" 항목은 권한이 필요할 때만 보인다.
    public var showsEscapePermissionItem: Bool
    public var showsTextFocusPermissionItem: Bool
    public var showsWindowSwitchPermissionItem: Bool
    /// 창 전환을 감지하지 못하고 있는 맨 앞 앱 이름(권한은 있지만 앱이 AX에 답하지 않음). 없으면 nil.
    public var windowSwitchStalledApp: String?
    /// 자동 전환 문구에 들어갈 목표 입력 소스 이름("Switch to ABC on ESC").
    public var defaultSourceName: String?
    /// 기본 입력 소스 서브메뉴에서 "자동" 항목에 보일 자동 선택 결과. 영문 배열이 없으면 nil.
    public var automaticSourceName: String?
    public var showHUD: Bool
    /// "기억한 입력 소스 지우기"는 복원을 하나라도 골랐을 때만 보인다.
    public var showsForgetItem: Bool

    public init(
        settings: KeyHueSettings,
        enabledSources: [InputSourceInfo],
        escape: FeatureStatus,
        textFocus: FeatureStatus,
        windowSwitch: FeatureStatus = .off,
        windowSwitchStalledApp: String? = nil
    ) {
        showStateBar = settings.showStateBar
        onAppSwitch = settings.onAppSwitch
        onWindowSwitch = settings.onWindowSwitch
        self.escape = escape
        self.windowSwitch = windowSwitch
        showsEscapePermissionItem = escape == .needsPermission
        showsTextFocusPermissionItem = textFocus == .needsPermission
        showsWindowSwitchPermissionItem = windowSwitch == .needsPermission
        // 창 옵션이 동작 중일 때만 의미가 있다(꺼져 있거나 권한이 없으면 다른 안내가 먼저다).
        self.windowSwitchStalledApp = windowSwitch == .active ? windowSwitchStalledApp : nil
        defaultSourceName = InputMethodIntegration.defaultSource(settings: settings, sources: enabledSources)?.displayName
        automaticSourceName = InputMethodIntegration.automaticSource(settings: settings, sources: enabledSources)?.displayName
        showHUD = settings.showHUD
        showsForgetItem = settings.rememberInputPerApp || settings.rememberInputPerWindow
    }
}

/// 메뉴 항목 체크 표시. `.mixed`는 켜 두었지만 동작하지 못함("–").
public enum MenuCheck: Sendable, Equatable {
    case off, on, mixed

    public init(_ status: FeatureStatus) {
        switch status {
        case .off: self = .off
        case .active: self = .on
        case .needsPermission: self = .mixed
        }
    }
}

/// "기본 입력 소스" 하위 메뉴: 자동 + (사용할 수 없는 저장값) + 켜져 있는 입력 소스.
public struct DefaultSourceMenu: Sendable, Equatable {
    public struct Choice: Sendable, Equatable {
        public var id: String
        public var title: String
        public var isChecked: Bool
    }

    /// 자동 선택 결과 이름. 고를 영문 배열이 없으면 nil.
    public var automaticName: String?
    public var isAutomaticChecked: Bool
    /// 저장한 기본값을 쓸 수 없을 때 체크된 채 비활성으로 보이는 항목.
    public var showsUnavailableChoice: Bool
    public var choices: [Choice]

    public init(settings: KeyHueSettings, sources: [InputSourceInfo]) {
        automaticName = InputMethodIntegration.automaticSource(settings: settings, sources: sources)?.displayName
        isAutomaticChecked = settings.defaultSourceID == nil
        showsUnavailableChoice = InputMethodIntegration.isDefaultUnavailable(settings: settings, sources: sources)
        choices = sources.map { Choice(id: $0.id, title: $0.displayName, isChecked: settings.defaultSourceID == $0.id) }
    }
}
