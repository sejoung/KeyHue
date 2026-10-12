import Foundation
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

/// 허용 여부: 이 프로세스와 새 프로세스가 보는 것.
@MainActor
protocol PermissionStatus: AnyObject {
    func has(_ permission: PermissionKind) -> Bool
    /// 새 프로세스가 보는 허용 여부(ADR 0084). 확인하지 못하면 false.
    func isGrantedInNewProcess(_ permission: PermissionKind) -> Bool
}

/// KeyHue가 띄우는 안내.
@MainActor
protocol PermissionPrompting: AnyObject {
    /// 왜 필요한지 설명하고, 사용자가 계속하기를 고르면 true.
    func explain(_ request: PermissionRequest) -> Bool
    func explainMissing(_ permission: PermissionKind, feature: String) -> PermissionPrompter.MissingChoice
    func openSettings(_ permission: PermissionKind)
}

/// macOS에 요청하고 끊긴 권한을 되살리는 동작.
@MainActor
protocol PermissionRecovery: AnyObject {
    /// 시스템 요청. 이미 결정된 권한이라 아무것도 뜨지 않으면 false.
    func request(_ permission: PermissionKind) -> Bool
    func resetStaleEntry(_ permission: PermissionKind)
    /// 항목을 지운 뒤의 요청. 이 프로세스는 처음 답을 기억해 목록에 다시 넣지 못한다(ADR 0084).
    func requestInNewProcess(_ permission: PermissionKind)
    /// 허용은 됐는데 이 프로세스만 모를 때: KeyHue를 다시 실행해 적용한다.
    func relaunchToApply(_ permission: PermissionKind)
}

/// 권한 흐름이 쓰는 전부. 시스템 권한·대화상자를 이 뒤에 두어 거절·실패 경로를 테스트한다.
typealias PermissionGate = PermissionStatus & PermissionPrompting & PermissionRecovery

@MainActor
final class SystemPermissionGate: PermissionGate {
    func has(_ permission: PermissionKind) -> Bool { SystemPermissions.has(permission) }
    func request(_ permission: PermissionKind) -> Bool { SystemPermissions.request(permission) }
    func explain(_ request: PermissionRequest) -> Bool {
        switch request {
        case .inputMonitoring(let feature): return PermissionPrompter.explain(.inputMonitoring, inputFeature: feature)
        case .accessibility(let feature): return PermissionPrompter.explain(.accessibility, for: feature)
        }
    }
    func openSettings(_ permission: PermissionKind) { PermissionPrompter.openSettings(permission) }
    func explainMissing(_ permission: PermissionKind, feature: String) -> PermissionPrompter.MissingChoice {
        PermissionPrompter.explainMissing(permission, feature: feature)
    }
    func resetStaleEntry(_ permission: PermissionKind) { PermissionPrompter.resetStaleEntry(permission) }
    func isGrantedInNewProcess(_ permission: PermissionKind) -> Bool {
        runWorker([WorkerCommand.permissionStatusFlag, permission.tccService])?.status == 0
    }
    func requestInNewProcess(_ permission: PermissionKind) {
        let status = runWorker([WorkerCommand.requestPermissionFlag, permission.tccService]).map { String($0.status) } ?? "failed"
        Log.app.notice("permission \(permission.tccService) requested from a new process status=\(status)")
    }
    func relaunchToApply(_ permission: PermissionKind) {
        do { try InputMethodSetup.relaunch(finishSetup: false, reason: "apply \(permission.tccService) allowed since launch") } catch {
            Log.app.error("relaunch to apply \(permission.tccService) failed: \(error)")
        }
    }
    private func runWorker(_ arguments: [String]) -> (status: Int32, output: Data)? {
        ProcessRunner.runSelf(arguments)
    }
}

@MainActor
struct PermissionFlow {
    let gate: PermissionGate

    /// 옵션을 켜기 전에 부른다. 권한이 없으면 설명하고 요청한다. 사용자가 설명에서 취소하면 false(옵션을 켜지 않는다).
    /// 요청 대화상자가 더 뜨지 않는 경우(이미 거절함)에는 시스템 설정을 연다. 허용은 나중에 반영될 수 있으므로 켠다.
    func allowEnabling(_ request: PermissionRequest) -> Bool {
        guard !gate.has(request.kind) else { return true }
        guard gate.explain(request) else { return false }
        if !gate.request(request.kind) { gate.openSettings(request.kind) }
        return true
    }

    /// 허용되지 않은 항목만 지우고 새로 요청한 뒤 시스템 설정을 연다(ADR 0021, 0084).
    /// 허용된 항목은 지우지 않는다. 방금 켠 허용까지 지워 목록에서 KeyHue가 사라졌다.
    func requestAgain(_ permission: PermissionKind) {
        if gate.has(permission) {
            gate.openSettings(permission)
            return
        }
        if gate.isGrantedInNewProcess(permission) {
            // 허용은 됐고 이 프로세스만 처음 답을 기억하고 있다.
            gate.relaunchToApply(permission)
            return
        }
        gate.resetStaleEntry(permission)
        gate.requestInNewProcess(permission)
        gate.openSettings(permission)
    }

    /// 실행 직후: 켜 둔 기능의 권한이 끊겼으면 한 번 알리고 사용자의 선택을 처리한다.
    /// - Returns: 알린 권한과 사용자의 선택. 알릴 것이 없으면 nil.
    @discardableResult
    func warnIfMissing(settings: KeyHueSettings, defaultName: String,
                       turnOff: (PermissionKind) -> Void) -> (PermissionKind, PermissionPrompter.MissingChoice)? {
        // Accessibility is checked only for a feature that uses it (ADR 0075).
        guard let permission = PermissionPolicy.missingOnLaunch(
            settings: settings, hasInputMonitoring: gate.has(.inputMonitoring),
            hasAccessibility: settings.usesAccessibility ? gate.has(.accessibility) : true
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
                    settings.routesInputMethodPair ? L("Keep KeyHue Korean/English Modes (Experimental)") : nil]
                .compactMap { $0 }.joined(separator: "”, “")
        case .accessibility where settings.watchesWindowSwitches:
            return L("When Switching Windows in the Same App") + " › "
                + settings.onWindowSwitch.title(defaultName: defaultName)
        case .accessibility:
            return L("Switch to %@ When Leaving Text Field", defaultName)
        }
    }
}
