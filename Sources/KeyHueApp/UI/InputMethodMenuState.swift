import KeyHueCore

/// 메뉴의 입력기 항목 상태. 무엇을 보이고 켤지는 여기서 정하고 메뉴는 그리기만 한다(ADR 0022, 0055).
struct InputMethodMenuState: Equatable {
    enum InstallAction: Equatable {
        case install, enable, update
    }

    var installAction: InstallAction
    var isInstallEnabled: Bool
    var isUninstallHidden: Bool
    var isUninstallEnabled: Bool
    var isIntegrationEnabled: Bool
    var integration: MenuCheck
    var isRoutingEnabled: Bool
    var routing: MenuCheck
    var isRoutingPermissionHidden: Bool
    /// "두 모드를 시스템 설정에서 추가하세요" 안내.
    var isNoticeHidden: Bool
    var isNoticeEnabled: Bool
    var isRecoveryHidden: Bool

    init(installation: InputMethodInstallationStatus, isBusy: Bool, settings: KeyHueSettings,
         sources: [InputSourceInfo], routingStatus: FeatureStatus) {
        installAction = installation.needsUpdate ? .update : (installation.isInstalled ? .enable : .install)
        isInstallEnabled = installation.hasPayload && !isBusy
        // 파일이 없어도 사용자가 남겨 둔 모드가 있으면 제거 안내를 받을 수 있게 보인다.
        isUninstallHidden = !installation.isInstalled && !installation.hasRegisteredSources
        isUninstallEnabled = !isBusy
        isIntegrationEnabled = !isBusy && (installation.hasPayload || settings.integrateInputMethod)
        let available = InputMethodIntegration.isAvailable(in: sources)
        integration = settings.integrateInputMethod ? (available ? .on : .mixed) : .off
        isRoutingEnabled = settings.integrateInputMethod && available && !isBusy
        routing = settings.routeInputMethodPair && settings.integrateInputMethod && !available ? .mixed : MenuCheck(routingStatus)
        isRoutingPermissionHidden = routingStatus != .needsPermission
        isNoticeHidden = !settings.integrateInputMethod || available
        isNoticeEnabled = !isBusy
        isRecoveryHidden = !settings.integrateInputMethod
    }
}

extension InputMethodMenuState.InstallAction {
    /// 메뉴와 설정 창의 설치 버튼 제목.
    var title: String {
        switch self {
        case .install: return L("Install and Use Input Method…")
        case .enable: return L("Enable Input Method…")
        case .update: return L("Update and Use Input Method…")
        }
    }
}
