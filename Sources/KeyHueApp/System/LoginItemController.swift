import ServiceManagement

/// Launch at Login. 상태의 원본은 ServiceManagement이며 UserDefaults에 따로 저장하지 않는다.
@MainActor
enum LoginItemController {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 사용자가 System Settings > Login Items에서 승인해야 하는 상태.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.loginItem.notice("launch at login set to \(enabled)")
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
