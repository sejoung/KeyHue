import AppKit
import KeyHueCore
import os

/// Composition root.
///
///     macOS Events → Monitors → InputStateStore → Overlay / HUD / StatusBar
///                        ↘ ResetPolicy → InputSourceController (ABC 전환)
///
/// UI 컴포넌트는 OS 이벤트를 직접 처리하지 않고 store의 변경만 구독한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "KeyHue", category: "State")

    private let settingsStore = SettingsStore()
    private let stateStore = InputStateStore()
    private let appMemory = AppInputMemory()

    private let inputSourceMonitor = InputSourceMonitor()
    private let capsLockMonitor = CapsLockMonitor()
    private let appFocusMonitor = AppFocusMonitor()
    private let keyboardMonitor = KeyboardMonitor()
    private let textFocusMonitor = TextFocusMonitor()

    private let overlay = OverlayController()
    private let hud = HUDController()
    private var statusBar: StatusBarController?

    private var activeScreen: NSScreen?
    private var isStarted = false

    private var settings: KeyHueSettings { settingsStore.settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        stateStore.addObserver { [weak self] old, new in self?.inputChanged(from: old, to: new) }
        settingsStore.addObserver { [weak self] old, new in self?.settingsChanged(from: old, to: new) }

        overlay.start()
        inputSourceMonitor.start { [weak self] source in self?.stateStore.updateSource(source) }
        capsLockMonitor.start { [weak self] isOn in self?.stateStore.updateCapsLock(isOn) }

        appFocusMonitor.onAppActivated = { [weak self] previous, current in
            self?.appActivated(previous: previous, current: current)
        }
        appFocusMonitor.onSpaceChanged = { [weak self] in self?.spaceChanged() }
        appFocusMonitor.onWake = { [weak self] in self?.resync() }
        appFocusMonitor.start()

        keyboardMonitor.onKeyDown = { [weak self] keyCode, isAutoRepeat in
            guard let self else { return }
            self.perform(ResetPolicy.onKeyDown(
                keyCode: keyCode,
                isAutoRepeat: isAutoRepeat,
                settings: self.settings,
                current: self.stateStore.snapshot.source
            ))
        }
        textFocusMonitor.onFocusChanged = { [weak self] wasText, isText in
            guard let self else { return }
            self.perform(ResetPolicy.onFocusChanged(
                wasTextInput: wasText,
                isTextInput: isText,
                settings: self.settings,
                current: self.stateStore.snapshot.source
            ))
        }

        statusBar = StatusBarController(settingsStore: settingsStore, stateStore: stateStore, actions: self)

        updateActiveScreen()
        overlay.apply(state: stateStore.state, settings: settings)
        updateKeyboardMonitor()
        updateTextFocusMonitor()
        isStarted = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputSourceMonitor.stop()
        capsLockMonitor.stop()
        appFocusMonitor.stop()
        keyboardMonitor.stop()
        textFocusMonitor.detach()
    }

    // MARK: - Store observers

    private func inputChanged(from old: InputSnapshot, to new: InputSnapshot) {
        Self.log.debug("state=\(new.state.rawValue, privacy: .public) source=\(new.source?.id ?? "-", privacy: .public)")
        overlay.apply(state: new.state, settings: settings)

        if isStarted, settings.showHUD, old.state != new.state {
            updateActiveScreen()
            hud.show(state: new.state, color: settings.color(for: new.state), on: activeScreen)
        }

        // 앱별 기억: 현재 활성 앱에서 Source가 바뀔 때마다 기록한다.
        if settings.rememberInputPerApp,
           let sourceID = new.source?.id, sourceID != old.source?.id,
           let bundleID = appFocusMonitor.current?.bundleID {
            appMemory.record(sourceID: sourceID, for: bundleID)
        }
    }

    private func settingsChanged(from old: KeyHueSettings, to new: KeyHueSettings) {
        if old.displayPolicy != new.displayPolicy || old.showHUD != new.showHUD {
            updateActiveScreen()
        }
        overlay.apply(state: stateStore.state, settings: new)
        if old.resetOnEscape != new.resetOnEscape {
            updateKeyboardMonitor()
        }
        if old.resetOnTextFocusLoss != new.resetOnTextFocusLoss {
            updateTextFocusMonitor()
        }
    }

    // MARK: - OS events

    private func appActivated(previous: AppFocusMonitor.ActiveApp?, current: AppFocusMonitor.ActiveApp) {
        // 이전 앱에서 Source 변경이 한 번도 없었던 경우를 위해, 전환 직전 Source를 이전 앱 몫으로 기록한다.
        if settings.rememberInputPerApp,
           let bundleID = previous?.bundleID,
           let sourceID = stateStore.snapshot.source?.id {
            appMemory.record(sourceID: sourceID, for: bundleID)
        }

        resync()
        updateActiveScreen()
        updateKeyboardMonitor()
        updateTextFocusMonitor()

        perform(ResetPolicy.onAppActivated(
            bundleID: current.bundleID,
            settings: settings,
            remembered: appMemory.entries,
            current: stateStore.snapshot.source
        ), after: Self.appSwitchSettleDelay)
    }

    private func spaceChanged() {
        overlay.bringToFront()
        updateActiveScreen()
        capsLockMonitor.refresh()
    }

    /// notification을 놓쳤을 수 있는 시점(앱 전환, 깨어남)에 실제 상태를 다시 읽는다.
    private func resync() {
        inputSourceMonitor.refresh()
        capsLockMonitor.refresh()
        overlay.bringToFront()
    }

    // MARK: - Actions

    /// 앱 활성화 직후에는 시스템(TSM)이 새 앱에 기존 Source를 다시 적용하므로, 그보다 먼저 전환하면
    /// 덮어써지거나 색이 한 번 깜빡인다. 활성화가 끝날 때까지 잠깐 기다린 뒤 전환한다.
    static let appSwitchSettleDelay: TimeInterval = 0.1
    /// 전환 결과 확인까지의 시간. 목표에 도달하지 않았으면 한 번만 재시도한다.
    static let verifyDelay: TimeInterval = 0.25

    /// 이벤트 처리(키 입력, 앱 활성화)가 끝난 뒤 전환한다. Timer polling이 아닌 1회성 예약이다.
    private func perform(_ action: InputSourceAction, after delay: TimeInterval = 0, retry: Bool = true) {
        guard action != .none else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 대기하는 사이 사용자가 직접 전환했을 수 있으므로 다시 확인한다.
                guard !ResetPolicy.isSatisfied(action, by: InputSourceController.current()) else { return }
                InputSourceController.perform(action)
                self.inputSourceMonitor.refresh()
                guard retry else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.verifyDelay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !ResetPolicy.isSatisfied(action, by: InputSourceController.current()) else { return }
                        Self.log.info("input source switch was overridden; retrying once")
                        self.perform(action, retry: false)
                    }
                }
            }
        }
    }

    private func updateActiveScreen() {
        guard settings.displayPolicy == .activeScreen || settings.showHUD else { return }
        activeScreen = ActiveScreenLocator.screen(forPID: appFocusMonitor.current?.pid)
        overlay.setActiveScreen(activeScreen)
    }

    private func updateKeyboardMonitor() {
        if settings.resetOnEscape {
            keyboardMonitor.start()
        } else {
            keyboardMonitor.stop()
        }
    }

    private func updateTextFocusMonitor() {
        if settings.resetOnTextFocusLoss, let pid = appFocusMonitor.current?.pid {
            textFocusMonitor.attach(to: pid)
        } else {
            textFocusMonitor.detach()
        }
    }

    private func terminateIfAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != .current }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - StatusBarActions

extension AppDelegate: StatusBarActions {
    var escapeResetStatus: FeatureStatus {
        guard settings.resetOnEscape else { return .off }
        // 메뉴를 열 때마다 재시도한다: 권한을 방금 허용했다면 여기서 시작된다.
        return keyboardMonitor.start() ? .active : .needsPermission
    }

    var textFocusResetStatus: FeatureStatus {
        guard settings.resetOnTextFocusLoss else { return .off }
        guard TextFocusMonitor.isTrusted else { return .needsPermission }
        updateTextFocusMonitor()
        return .active
    }

    var isLaunchAtLoginEnabled: Bool {
        LoginItemController.isEnabled
    }

    func setResetOnEscape(_ enabled: Bool) {
        if enabled, !KeyboardMonitor.hasPermission {
            guard PermissionPrompter.explain(.inputMonitoring) else { return }
            if !KeyboardMonitor.requestPermission() {
                PermissionPrompter.openSettings(.inputMonitoring)
            }
        }
        settingsStore.update { $0.resetOnEscape = enabled }
    }

    func setResetOnTextFocusLoss(_ enabled: Bool) {
        if enabled, !TextFocusMonitor.isTrusted {
            guard PermissionPrompter.explain(.accessibility) else { return }
            TextFocusMonitor.requestTrust()
        }
        settingsStore.update { $0.resetOnTextFocusLoss = enabled }
    }

    func openInputMonitoringSettings() {
        if !KeyboardMonitor.requestPermission() {
            PermissionPrompter.openSettings(.inputMonitoring)
        }
    }

    func openAccessibilitySettings() {
        if !TextFocusMonitor.requestTrust() {
            PermissionPrompter.openSettings(.accessibility)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            if enabled, LoginItemController.requiresApproval {
                LoginItemController.openSystemSettings()
            }
        } catch {
            PermissionPrompter.showError("Couldn't change Launch at Login", error)
        }
    }

    func forgetPerAppInputs() {
        appMemory.clear()
    }
}
