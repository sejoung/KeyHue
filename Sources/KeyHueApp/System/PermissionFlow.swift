import KeyHueCore

/// 권한이 필요한 옵션을 켤 때와, 켜 둔 옵션의 권한이 끊겼을 때의 흐름(ADR 0021).
/// 시스템 권한·대화상자는 `PermissionGate` 뒤에 두어 거절·실패 경로를 테스트할 수 있게 한다.
enum PermissionRequest: Equatable {
    case inputMonitoring(PermissionPrompter.InputMonitoringFeature)
    case accessibility(PermissionPrompter.AccessibilityFeature)

    var kind: PermissionKind {
        switch self {
        case .inputMonitoring: return .inputMonitoring
        case .accessibility: return .accessibility
        }
    }
}

@MainActor
protocol PermissionGate: AnyObject {
    var hasInputMonitoring: Bool { get }
    var hasAccessibility: Bool { get }
    /// 왜 필요한지 설명하고, 사용자가 계속하기를 고르면 true.
    func explain(_ request: PermissionRequest) -> Bool
    /// 시스템 요청 대화상자. 이미 결정된 권한이면 false를 돌려준다.
    func requestInputMonitoring() -> Bool
    func requestAccessibility()
    func openSettings(_ permission: PermissionKind)
    func explainMissing(_ permission: PermissionKind, feature: String) -> PermissionPrompter.MissingChoice
    func resetStaleEntry(_ permission: PermissionKind)
}

@MainActor
final class SystemPermissionGate: PermissionGate {
    var hasInputMonitoring: Bool { KeyboardMonitor.hasPermission }
    var hasAccessibility: Bool { AccessibilityFocusMonitor.isTrusted }
    func explain(_ request: PermissionRequest) -> Bool {
        switch request {
        case .inputMonitoring(let feature): return PermissionPrompter.explain(.inputMonitoring, inputFeature: feature)
        case .accessibility(let feature): return PermissionPrompter.explain(.accessibility, for: feature)
        }
    }
    func requestInputMonitoring() -> Bool { KeyboardMonitor.requestPermission() }
    func requestAccessibility() { _ = AccessibilityFocusMonitor.requestTrust() }
    func openSettings(_ permission: PermissionKind) { PermissionPrompter.openSettings(permission) }
    func explainMissing(_ permission: PermissionKind, feature: String) -> PermissionPrompter.MissingChoice {
        PermissionPrompter.explainMissing(permission, feature: feature)
    }
    func resetStaleEntry(_ permission: PermissionKind) { PermissionPrompter.resetStaleEntry(permission) }
}

@MainActor
struct PermissionFlow {
    let gate: PermissionGate

    func has(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .inputMonitoring: return gate.hasInputMonitoring
        case .accessibility: return gate.hasAccessibility
        }
    }

    /// 옵션을 켜기 전에 부른다. 권한이 없으면 설명하고 요청한다. 사용자가 설명에서 취소하면 false(옵션을 켜지 않는다).
    /// 요청 대화상자가 더 뜨지 않는 경우(이미 거절함)에는 시스템 설정을 연다. 허용은 나중에 반영될 수 있으므로 켠다.
    func allowEnabling(_ request: PermissionRequest) -> Bool {
        guard !has(request.kind) else { return true }
        guard gate.explain(request) else { return false }
        switch request {
        case .inputMonitoring:
            if !gate.requestInputMonitoring() { gate.openSettings(.inputMonitoring) }
        case .accessibility:
            gate.requestAccessibility()
        }
        return true
    }

    /// 이전 서명의 항목을 지우고 새로 요청한 뒤 시스템 설정을 연다.
    func requestAgain(_ permission: PermissionKind) {
        gate.resetStaleEntry(permission)
        switch permission {
        case .inputMonitoring: _ = gate.requestInputMonitoring()
        case .accessibility: gate.requestAccessibility()
        }
        gate.openSettings(permission)
    }

    /// 실행 직후: 켜 둔 기능의 권한이 끊겼으면 한 번 알리고 사용자의 선택을 처리한다.
    /// - Returns: 알린 권한과 사용자의 선택. 알릴 것이 없으면 nil.
    @discardableResult
    func warnIfMissing(settings: KeyHueSettings, defaultName: String,
                       turnOff: (PermissionKind) -> Void) -> (PermissionKind, PermissionPrompter.MissingChoice)? {
        // Accessibility is checked only for a feature that uses it (ADR 0075).
        guard let permission = PermissionPolicy.missingOnLaunch(
            settings: settings, hasInputMonitoring: gate.hasInputMonitoring,
            hasAccessibility: settings.usesAccessibility ? gate.hasAccessibility : true
        ) else { return nil }
        Log.app.notice("permission missing for enabled feature: \(permission.tccService)")
        let choice = gate.explainMissing(permission, feature: Self.featureText(for: permission, settings: settings, defaultName: defaultName))
        switch choice {
        case .allowAgain: requestAgain(permission)
        case .turnOff: turnOff(permission)
        case .later: break
        }
        return (permission, choice)
    }

    /// "끄기"는 이 권한을 쓰는 기능을 모두 끄므로, 켜 둔 것을 모두 이름으로 보여 준다.
    static func featureText(for permission: PermissionKind, settings: KeyHueSettings, defaultName: String) -> String {
        switch permission {
        case .inputMonitoring:
            return [settings.resetOnEscape ? L("Switch to %@ on ESC", defaultName) : nil,
                    settings.warnOnWrongLanguage ? L("Warn When Korean and English Are Mixed Up") : nil,
                    settings.integrateInputMethod && settings.routeInputMethodPair ? L("Keep KeyHue Korean/English Modes (Experimental)") : nil]
                .compactMap { $0 }.joined(separator: "”, “")
        case .accessibility where settings.watchesWindowSwitches:
            return L("When Switching Windows in the Same App") + " › "
                + StatusBarController.title(for: settings.onWindowSwitch, defaultName: defaultName)
        case .accessibility:
            return L("Switch to %@ When Leaving Text Field", defaultName)
        }
    }
}
