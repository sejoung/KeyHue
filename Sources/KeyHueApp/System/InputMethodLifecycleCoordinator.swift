import AppKit
import KeyHueCore

/// Owns the install/remove lifecycle and its effects on input routing.
/// AppDelegate supplies the few operations that require app UI or process relaunch.
@MainActor
final class InputMethodLifecycleCoordinator {
    private let manager: InputMethodManager
    private let settingsStore: SettingsStore
    private let switching: InputSwitching
    private let inputSourceMonitor: InputSourceMonitor
    private let preferences: InputMethodSourcePreferences
    /// Returns once ABC is selected (or selecting it failed).
    private let pauseIntegration: @MainActor () async -> Void
    private let refreshStatus: @MainActor () -> Void
    /// The modes macOS already lists as added (a reinstall can bring back kept ones, ADR 0087).
    private let promptToAddModes: @MainActor (_ alreadyAdded: Set<String>) -> Void
    /// After a confirmed removal: the modes macOS kept in its list.
    private let reportKeptModes: @MainActor ([String]) -> Void
    private let selectHangulAfterSetup: @MainActor () -> Bool
    private let relaunch: @MainActor (Bool) throws -> Void
    private let reportFailure: @MainActor (Error) -> Void

    /// An install or remove is in progress. AppDelegate reads this to hold back automatic switching.
    private(set) var isRunning = false

    init(
        manager: InputMethodManager,
        settingsStore: SettingsStore,
        switching: InputSwitching,
        inputSourceMonitor: InputSourceMonitor,
        preferences: InputMethodSourcePreferences = .shared,
        pauseIntegration: @escaping @MainActor () async -> Void,
        refreshStatus: @escaping @MainActor () -> Void,
        promptToAddModes: @escaping @MainActor (_ alreadyAdded: Set<String>) -> Void,
        reportKeptModes: @escaping @MainActor ([String]) -> Void,
        selectHangulAfterSetup: @escaping @MainActor () -> Bool,
        relaunch: @escaping @MainActor (Bool) throws -> Void,
        reportFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.manager = manager
        self.settingsStore = settingsStore
        self.switching = switching
        self.inputSourceMonitor = inputSourceMonitor
        self.preferences = preferences
        self.pauseIntegration = pauseIntegration
        self.refreshStatus = refreshStatus
        self.promptToAddModes = promptToAddModes
        self.reportKeptModes = reportKeptModes
        self.selectHangulAfterSetup = selectHangulAfterSetup
        self.relaunch = relaunch
        self.reportFailure = reportFailure
    }

    /// - Parameter ignoringModes: removing after the user confirmed the modes are gone from System Settings.
    func manage(removing: Bool, ignoringModes: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        refreshStatus()

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Prevent an IMK mode restore while the bundle is stopped or replaced. Wait for
            // ABC: the manager refuses while a KeyHue mode is still selected.
            await self.pauseIntegration()
            if let failure = await self.run(removing: removing, ignoringModes: ignoringModes) {
                // Reported once this operation has ended: the alert can start the next one
                // ("Remove Anyway"), which a running operation would ignore.
                self.reportFailure(failure)
            }
        }
    }

    /// Ends the operation (`isRunning` false) before returning its failure, if any.
    private func run(removing: Bool, ignoringModes: Bool) async -> Error? {
        defer {
            isRunning = false
            refreshStatus()
        }
        do {
            let finishSetup = try await perform(removing: removing, ignoringModes: ignoringModes)
            inputSourceMonitor.refresh()
            if preferences.isSupported && manager.requiresRelaunch {
                try relaunch(finishSetup)
            } else if finishSetup {
                guard selectHangulAfterSetup() else { throw InputMethodManagementError.systemFailure }
                switching.resetRouting()
                inputSourceMonitor.refresh()
            }
            return nil
        } catch {
            await pauseIntegration()
            inputSourceMonitor.refresh()
            return error
        }
    }

    private func perform(removing: Bool, ignoringModes: Bool) async throws -> Bool {
        if removing {
            let kept = try await manager.uninstall(ignoringModes: ignoringModes)
            settingsStore.update { $0.routeInputMethodPair = false }
            Log.app.notice("input method removed")
            // Before the macOS 26 relaunch: the alert waits for the user.
            if !kept.isEmpty { reportKeptModes(kept) }
            return false
        }

        let ready = try await manager.install()
        // The new server answers for itself; earlier silences no longer apply (ADR 0070).
        switching.sessionRepair.forgetUnrepairedApps()
        // Keep the user's setup request until both modes are enabled. Availability gates routing and defaults.
        settingsStore.update {
            $0.integrateInputMethod = true
            $0.routeInputMethodPair = true
        }
        if ready {
            switching.autoReset.cancelPendingWork()
            Log.app.notice("bundled input method installed; both modes already added")
        } else {
            promptToAddModes(manager.addedModeIDs)
            Log.app.notice("bundled input method installed; waiting for both modes to be enabled")
        }
        return ready
    }
}
