import AppKit
import KeyHueCore

/// Owns the install/remove lifecycle and its effects on input routing.
/// AppDelegate supplies the few operations that require app UI or process relaunch.
@MainActor
final class InputMethodLifecycleCoordinator {
    private let manager: InputMethodManager
    private let settingsStore: SettingsStore
    private let sessionRepair: InputMethodSessionRepair
    private let autoReset: AutoResetCoordinator
    private let inputSourceMonitor: InputSourceMonitor
    private let inputMethodRouter: InputMethodRoutingCoordinator
    private let pauseIntegration: @MainActor () -> Void
    private let refreshStatus: @MainActor () -> Void
    private let promptToAddModes: @MainActor () -> Void
    private let selectHangulAfterSetup: @MainActor () -> Bool
    private let relaunch: @MainActor (Bool) throws -> Void
    private let reportFailure: @MainActor (Error) -> Void

    /// An install or remove is in progress. AppDelegate reads this to hold back automatic switching.
    private(set) var isRunning = false

    init(
        manager: InputMethodManager,
        settingsStore: SettingsStore,
        sessionRepair: InputMethodSessionRepair,
        autoReset: AutoResetCoordinator,
        inputSourceMonitor: InputSourceMonitor,
        inputMethodRouter: InputMethodRoutingCoordinator,
        pauseIntegration: @escaping @MainActor () -> Void,
        refreshStatus: @escaping @MainActor () -> Void,
        promptToAddModes: @escaping @MainActor () -> Void,
        selectHangulAfterSetup: @escaping @MainActor () -> Bool,
        relaunch: @escaping @MainActor (Bool) throws -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.manager = manager
        self.settingsStore = settingsStore
        self.sessionRepair = sessionRepair
        self.autoReset = autoReset
        self.inputSourceMonitor = inputSourceMonitor
        self.inputMethodRouter = inputMethodRouter
        self.pauseIntegration = pauseIntegration
        self.refreshStatus = refreshStatus
        self.promptToAddModes = promptToAddModes
        self.selectHangulAfterSetup = selectHangulAfterSetup
        self.relaunch = relaunch
        self.reportFailure = reportFailure
    }

    func manage(removing: Bool) {
        guard !isRunning else { return }
        isRunning = true
        // Prevent an IMK mode restore while the bundle is stopped or replaced.
        pauseIntegration()
        refreshStatus()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRunning = false
                self.refreshStatus()
            }
            do {
                let finishSetup = try await self.perform(removing: removing)
                self.inputSourceMonitor.refresh()
                if InputMethodSourcePreferences.shared.isSupported && self.manager.requiresRelaunch {
                    try self.relaunch(finishSetup)
                } else if finishSetup {
                    guard self.selectHangulAfterSetup() else { throw InputMethodManagementError.systemFailure }
                    self.inputMethodRouter.reset(current: InputSourceController.current())
                    self.inputSourceMonitor.refresh()
                }
            } catch {
                self.pauseIntegration()
                self.inputSourceMonitor.refresh()
                self.reportFailure(error)
            }
        }
    }

    private func perform(removing: Bool) async throws -> Bool {
        if removing {
            try await manager.uninstall()
            settingsStore.update { $0.routeInputMethodPair = false }
            Log.app.notice("input method removed")
            return false
        }

        let ready = try await manager.install()
        // The new server answers for itself; earlier silences no longer apply (ADR 0070).
        sessionRepair.forgetUnrepairedApps()
        // Keep the user's setup request until both modes are enabled. Availability gates routing and defaults.
        settingsStore.update {
            $0.integrateInputMethod = true
            $0.routeInputMethodPair = true
        }
        if ready {
            autoReset.cancelPendingWork()
            Log.app.notice("bundled input method installed; both modes already added")
        } else {
            promptToAddModes()
            Log.app.notice("bundled input method installed; waiting for both modes to be enabled")
        }
        return ready
    }
}
