import KeyHueCore

/// 메뉴와 설정 창의 입력기 항목 상태. 무엇을 보이고 켤지는 여기서 정하고 화면은 그리기만 한다(ADR 0022, 0055).
/// 상태 한 줄과 다음에 할 일 하나를 보이고, 드물게 쓰는 동작은 관리 메뉴에 둔다(ADR 0069).
struct InputMethodMenuState: Equatable {
    enum InstallAction: Equatable {
        case install, enable, update
    }

    enum Phase: Equatable {
        /// 이 KeyHue에 입력기가 들어 있지 않다(번들 없이 실행).
        case unavailable
        case notInstalled
        /// 설치했지만 연동을 쉬고 있다.
        case off
        case needsUpdate
        /// 사용을 골랐지만 시스템 설정에 두 모드가 아직 없다.
        case waitingForModes
        case active
    }

    enum NextStep: Equatable {
        case install(InstallAction)
        case openInputSources
    }

    var phase: Phase
    var nextStep: NextStep?
    var isNextStepEnabled: Bool
    var isBusy: Bool
    /// 관리 메뉴: 모드 유지, 연동 끄기, 제거.
    var showsManageMenu: Bool
    var isRoutingHidden: Bool

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
        isRoutingHidden = !settings.integrateInputMethod
        self.isBusy = isBusy
        showsManageMenu = !isUninstallHidden || settings.integrateInputMethod

        if !installation.isInstalled {
            phase = installation.hasPayload ? .notInstalled : .unavailable
        } else if installation.needsUpdate {
            phase = .needsUpdate
        } else if !settings.integrateInputMethod {
            phase = .off
        } else {
            phase = available ? .active : .waitingForModes
        }
        switch phase {
        case .unavailable, .active: nextStep = nil
        case .notInstalled: nextStep = .install(.install)
        case .off: nextStep = .install(.enable)
        case .needsUpdate: nextStep = .install(.update)
        case .waitingForModes: nextStep = .openInputSources
        }
        switch nextStep {
        case .install?: isNextStepEnabled = isInstallEnabled
        case .openInputSources?: isNextStepEnabled = isNoticeEnabled
        case nil: isNextStepEnabled = false
        }
    }
}

extension InputMethodMenuState.Phase {
    /// 설정 창과 메뉴의 상태 한 줄.
    var title: String {
        switch self {
        case .unavailable: return L("Not Included in This Copy of KeyHue")
        case .notInstalled: return L("Not Installed")
        case .off: return L("Installed · Off")
        case .needsUpdate: return L("Update Available")
        case .waitingForModes: return L("Add Both Modes in System Settings")
        case .active: return L("In Use")
        }
    }
}

extension InputMethodMenuState.NextStep {
    var title: String {
        switch self {
        case .install(let action): return action.title
        case .openInputSources: return L("Open Input Source Settings")
        }
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
