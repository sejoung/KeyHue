import Foundation

/// 자동 전환 판단 결과. 실제 전환은 앱 레이어의 InputSourceController가 수행한다.
public enum InputSourceAction: Sendable, Equatable {
    case none
    case selectABC
    case select(sourceID: String)
}

/// "언제 ABC로 되돌릴지"에 대한 순수 판단 로직.
public enum ResetPolicy {
    public static let escapeKeyCode: Int64 = 53

    /// 앱 전환 시
    /// 1. 앱별 기억이 켜져 있고 해당 앱의 기록이 있으면 그 Source를 복원한다.
    /// 2. 아니면 ABC 전환 옵션에 따라 ABC로 전환한다.
    /// 이미 목표 상태라면 아무것도 하지 않는다(불필요한 TIS 호출/notification 방지).
    public static func onAppActivated(
        bundleID: String?,
        settings: KeyHueSettings,
        remembered: [String: String],
        current: InputSourceInfo?
    ) -> InputSourceAction {
        if settings.rememberInputPerApp, let bundleID, let saved = remembered[bundleID] {
            return saved == current?.id ? .none : .select(sourceID: saved)
        }
        if settings.resetOnAppSwitch {
            return resetToEnglish(current: current)
        }
        return .none
    }

    public static func onKeyDown(
        keyCode: Int64,
        isAutoRepeat: Bool,
        settings: KeyHueSettings,
        current: InputSourceInfo?
    ) -> InputSourceAction {
        guard settings.resetOnEscape, keyCode == escapeKeyCode, !isAutoRepeat else { return .none }
        return resetToEnglish(current: current)
    }

    /// 텍스트 입력 요소에서 비-텍스트 요소로 focus가 옮겨간 순간에만 전환한다.
    public static func onFocusChanged(
        wasTextInput: Bool,
        isTextInput: Bool,
        settings: KeyHueSettings,
        current: InputSourceInfo?
    ) -> InputSourceAction {
        guard settings.resetOnTextFocusLoss, wasTextInput, !isTextInput else { return .none }
        return resetToEnglish(current: current)
    }

    /// 전환 후 실제 Source가 목표에 도달했는지. 앱 활성화 직후 시스템이 이전 Source를 다시 적용하는
    /// 경쟁 상황을 감지해 한 번 재시도하는 데 쓴다.
    public static func isSatisfied(_ action: InputSourceAction, by current: InputSourceInfo?) -> Bool {
        switch action {
        case .none: return true
        case .selectABC: return current?.kind == .english
        case .select(let sourceID): return current?.id == sourceID
        }
    }

    /// 이미 English 계열(ABC, U.S. 등)이면 그대로 둔다.
    static func resetToEnglish(current: InputSourceInfo?) -> InputSourceAction {
        current?.kind == .english ? .none : .selectABC
    }
}

/// 활성화된 키보드 Input Source 목록에서 "ABC로 되돌리기"의 대상 Source를 고른다.
public enum ABCSourcePicker {
    public static let preferredIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US"
    ]

    public static func pick(from candidates: [InputSourceInfo]) -> InputSourceInfo? {
        for id in preferredIDs {
            if let match = candidates.first(where: { $0.id == id }) {
                return match
            }
        }
        let english = candidates.filter { $0.kind == .english }
        return english.first(where: { $0.id.hasPrefix("com.apple.keylayout.") }) ?? english.first
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
