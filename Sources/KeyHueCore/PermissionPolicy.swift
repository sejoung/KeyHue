import Foundation

/// 권한이 필요한 옵션의 현재 상태.
public enum FeatureStatus: Sendable, Equatable {
    case off
    case active
    case needsPermission
}

/// 옵션 기능이 쓰는 macOS 개인정보 보호 권한.
public enum PermissionKind: String, Sendable, Equatable, CaseIterable {
    case inputMonitoring
    case accessibility

    /// `tccutil`의 서비스 이름.
    public var tccService: String {
        switch self {
        case .inputMonitoring: return "ListenEvent"
        case .accessibility: return "Accessibility"
        }
    }
}

/// 권한과 관련된 순수 판단(ADR 0008, 0021).
public enum PermissionPolicy {
    /// 켜 두었고 실제로 동작하면 active, 켜 두었는데 동작하지 못하면(권한 없음) needsPermission.
    public static func status(isEnabled: Bool, isWorking: Bool) -> FeatureStatus {
        guard isEnabled else { return .off }
        return isWorking ? .active : .needsPermission
    }

    /// 앱 시작 시 알려야 할 끊긴 권한. 켜지 않은 기능의 권한은 묻지 않는다. ESC를 먼저 본다.
    public static func missingOnLaunch(
        settings: KeyHueSettings,
        hasInputMonitoring: Bool,
        hasAccessibility: Bool
    ) -> PermissionKind? {
        if settings.resetOnEscape, !hasInputMonitoring {
            return .inputMonitoring
        }
        if settings.resetOnTextFocusLoss || settings.watchesWindowSwitches, !hasAccessibility {
            return .accessibility
        }
        return nil
    }

    /// 사용자가 "끄기"를 고르면 해당 권한을 쓰는 기능을 끈다.
    public static func disableFeature(needing permission: PermissionKind, in settings: inout KeyHueSettings) {
        switch permission {
        case .inputMonitoring: settings.resetOnEscape = false
        case .accessibility:
            settings.resetOnTextFocusLoss = false
            settings.onWindowSwitch = .keep
        }
    }
}

/// 켜진 옵션에 따라 손쉬운 사용 API로 무엇을 관찰할지. 필요한 것만 구독·조회한다.
public struct AccessibilityUse: Sendable, Equatable {
    /// 텍스트 필드 이탈: 포커스 변경 알림 + 포커스 요소의 역할 조회
    public var textFocus: Bool
    /// 창 전환: 메인 창 변경 알림 + 메인 창 조회
    public var windowSwitches: Bool

    public init(textFocus: Bool, windowSwitches: Bool) {
        self.textFocus = textFocus
        self.windowSwitches = windowSwitches
    }

    public var isEmpty: Bool { !textFocus && !windowSwitches }
}

extension KeyHueSettings {
    public var accessibilityUse: AccessibilityUse {
        AccessibilityUse(textFocus: resetOnTextFocusLoss, windowSwitches: watchesWindowSwitches)
    }
}
