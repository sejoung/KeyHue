import Foundation

/// 자동 전환 판단 결과. 실제 전환은 앱 레이어의 InputSourceController가 수행한다.
public enum InputSourceAction: Sendable, Equatable {
    case none
    /// 기본 입력 소스로 전환. preferredID가 없거나 더 이상 켜져 있지 않으면 자동으로 고른다.
    case selectDefault(preferredID: String?)
    case select(sourceID: String)
}

/// "언제 기본 입력 소스로 되돌릴지"에 대한 순수 판단 로직.
public enum ResetPolicy {
    public static let escapeKeyCode: Int64 = 53

    /// 앱 전환 시 `onAppSwitch`를 따른다(ADR 0029). "마지막 입력 소스로 복원"이면
    /// 1. 창 전환도 복원이고 새 앱의 앞 창 기록이 있으면 그 Source(가장 구체적)
    /// 2. 해당 앱의 기록이 있으면 그 Source
    /// 3. 처음 가는 앱이면 기본 입력 소스
    /// 이미 목표 상태라면 아무것도 하지 않는다(불필요한 TIS 호출/notification 방지).
    public static func onAppActivated(
        bundleID: String?,
        settings: KeyHueSettings,
        remembered: [String: String],
        rememberedForWindow: String? = nil,
        current: InputSourceInfo?
    ) -> InputSourceAction {
        switch settings.onAppSwitch {
        case .keep:
            return .none
        case .switchToDefault:
            return resetToDefault(current: current, settings: settings)
        case .restoreLast:
            if settings.rememberInputPerWindow, let saved = rememberedForWindow {
                return restore(saved, current: current)
            }
            if let bundleID, let saved = remembered[bundleID] {
                return restore(saved, current: current)
            }
            return resetToDefault(current: current, settings: settings)
        }
    }

    public static func onKeyDown(
        keyCode: Int64,
        isAutoRepeat: Bool,
        settings: KeyHueSettings,
        current: InputSourceInfo?
    ) -> InputSourceAction {
        guard settings.resetOnEscape, keyCode == escapeKeyCode, !isAutoRepeat else { return .none }
        return resetToDefault(current: current, settings: settings)
    }

    /// 텍스트 입력 요소에서 비-텍스트 요소로 focus가 옮겨간 순간에만 전환한다.
    public static func onFocusChanged(
        wasTextInput: Bool,
        isTextInput: Bool,
        settings: KeyHueSettings,
        current: InputSourceInfo?
    ) -> InputSourceAction {
        guard settings.resetOnTextFocusLoss, wasTextInput, !isTextInput else { return .none }
        return resetToDefault(current: current, settings: settings)
    }

    /// 같은 앱 안에서 다른 창(탭)으로 옮겼을 때 `onWindowSwitch`를 따른다.
    /// "마지막 입력 소스로 복원"인데 처음 보는 창(⌘N 등)이면 기본 입력 소스로 전환한다.
    public static func onWindowSwitched(
        settings: KeyHueSettings,
        rememberedForWindow: String? = nil,
        current: InputSourceInfo?
    ) -> InputSourceAction {
        switch settings.onWindowSwitch {
        case .keep:
            return .none
        case .switchToDefault:
            return resetToDefault(current: current, settings: settings)
        case .restoreLast:
            if let saved = rememberedForWindow {
                return restore(saved, current: current)
            }
            return resetToDefault(current: current, settings: settings)
        }
    }

    static func restore(_ sourceID: String, current: InputSourceInfo?) -> InputSourceAction {
        sourceID == current?.id ? .none : .select(sourceID: sourceID)
    }

    /// 전환 후 실제 Source가 목표에 도달했는지. 앱 활성화 직후 시스템이 이전 Source를 다시 적용하는
    /// 경쟁 상황을 감지해 한 번 재시도하는 데 쓴다.
    public static func isSatisfied(_ action: InputSourceAction, by current: InputSourceInfo?) -> Bool {
        switch action {
        case .none: return true
        case .selectDefault(let preferredID?): return current?.id == preferredID
        case .selectDefault(nil): return current?.isASCIIBase == true
        case .select(let sourceID): return current?.id == sourceID
        }
    }

    /// - 기본 입력 소스를 직접 지정했다면 정확히 그 Source여야 한다.
    /// - 자동이면 이미 영문 배열(ABC, U.S., German…)일 때 그대로 둔다.
    static func resetToDefault(current: InputSourceInfo?, settings: KeyHueSettings) -> InputSourceAction {
        let action = InputSourceAction.selectDefault(preferredID: settings.defaultSourceID)
        return isSatisfied(action, by: current) ? .none : action
    }
}

/// 켜져 있는 키보드 Input Source 중 "기본 입력 소스"를 고른다.
public enum DefaultInputSourcePicker {
    public static let preferredIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US"
    ]

    /// 1. 사용자가 지정한 Source(켜져 있을 때)
    /// 2. ABC → U.S.
    /// 3. 첫 번째 영문 keylayout(German, Dvorak…) → 첫 번째 영문 배열
    public static func pick(from candidates: [InputSourceInfo], preferredID: String? = nil) -> InputSourceInfo? {
        if let preferredID, let match = candidates.first(where: { $0.id == preferredID }) {
            return match
        }
        for id in preferredIDs {
            if let match = candidates.first(where: { $0.id == id }) {
                return match
            }
        }
        let base = candidates.filter(\.isASCIIBase)
        return base.first(where: { $0.id.hasPrefix("com.apple.keylayout.") }) ?? base.first
    }
}

/// Accessibility role 기준 텍스트 입력 요소 판정.
public enum TextInputRole {
    static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let subroles: Set<String> = ["AXSearchField", "AXSecureTextField"]

    public static func isTextInput(role: String?, subrole: String?, isEditable: Bool? = nil) -> Bool {
        if isEditable == true {
            return true
        }
        if let role, roles.contains(role) {
            return true
        }
        if let subrole, subroles.contains(subrole) {
            return true
        }
        return false
    }
}
