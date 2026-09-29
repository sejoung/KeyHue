import AppKit
import KeyHueCore
import os

/// Composition root.
///
///     macOS Events → Monitors → InputStateStore → Overlay / HUD / StatusBar
///                        ↘ AutoResetCoordinator(Core) → InputSourceController (기본 입력 소스로 전환)
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
    private let focusMonitor = AccessibilityFocusMonitor()

    private let overlay = OverlayController()
    private let hud = HUDController()
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    private var activeScreen: NSScreen?
    private var isStarted = false

    /// 자동 전환의 "언제·재시도" 판단은 Core에 있다(테스트 대상). 여기서는 실제 TIS와 main queue를 연결한다.
    private lazy var autoReset = AutoResetCoordinator(
        switcher: SystemInputSourceSwitcher(),
        scheduler: MainQueueScheduler(),
        memory: appMemory,
        settings: { [unowned self] in self.settings }
    )

    private var settings: KeyHueSettings { settingsStore.settings }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // UI를 만들기 전에 앱 언어와 Dock 표시 여부를 적용한다.
        Localization.apply(settings.appLanguage)
        applyDockIconPolicy()
    }

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

        autoReset.onEvent = { [weak self] event in
            Self.log.debug("auto reset: \(String(describing: event), privacy: .public) now=\(InputSourceController.current()?.id ?? "-", privacy: .public)")
            switch event {
            case .switched, .retrying: self?.inputSourceMonitor.refresh()
            case .skipped: break
            }
        }
        keyboardMonitor.onKeyDown = { [weak self] keyCode, isAutoRepeat in
            guard let self else { return }
            // 타이핑을 시작하면 HUD를 바로 숨긴다(어떤 키인지는 보지 않는다, ADR 0025).
            self.hud.hideNow()
            self.autoReset.keyDown(keyCode: keyCode, isAutoRepeat: isAutoRepeat, current: self.stateStore.snapshot.source)
        }
        focusMonitor.onWindowSwitched = { [weak self] previous, window in
            guard let self else { return }
            Self.log.debug("window switched within \(self.appFocusMonitor.current?.bundleID ?? "-", privacy: .public)")
            self.autoReset.windowSwitched(
                from: previous.map(AnyHashable.init),
                to: AnyHashable(window),
                current: self.stateStore.snapshot.source
            )
        }
        focusMonitor.onFocusChanged = { [weak self] wasText, isText in
            guard let self else { return }
            self.autoReset.focusChanged(wasTextInput: wasText, isTextInput: isText, current: self.stateStore.snapshot.source)
        }

        statusBar = StatusBarController(settingsStore: settingsStore, stateStore: stateStore, actions: self)
        settingsWindow = SettingsWindowController(model: SettingsModel(store: settingsStore, actions: self))
        installMainMenu()

        updateActiveScreen()
        if settings.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: settings)
        updateKeyboardMonitor()
        updateFocusMonitor()
        isStarted = true
        // 메뉴바가 자리 잡은 뒤, 켜 둔 기능의 권한이 끊겼는지 확인한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.warnIfPermissionMissing() }
        }
    }

    /// ESC/텍스트 필드/창 전환을 켜 두었는데 권한이 없으면 한 번 알린다(업데이트·재빌드 뒤 흔하다).
    private func warnIfPermissionMissing() {
        guard let permission = PermissionPolicy.missingOnLaunch(
            settings: settings,
            hasInputMonitoring: KeyboardMonitor.hasPermission,
            hasAccessibility: AccessibilityFocusMonitor.isTrusted
        ) else { return }
        Self.log.info("permission missing for enabled feature: \(permission.tccService, privacy: .public)")

        let defaultName = InputSourceController.resolvedDefaultSource(preferredID: settings.defaultSourceID)?.displayName
            ?? StatusMenuState.fallbackSourceName
        let feature = switch permission {
        case .inputMonitoring: L("Switch to %@ on ESC", defaultName)
        case .accessibility where settings.watchesWindowSwitches:
            L("When Switching Windows in the Same App") + " › "
                + StatusBarController.title(for: settings.onWindowSwitch, defaultName: defaultName)
        case .accessibility: L("Switch to %@ When Leaving Text Field", defaultName)
        }
        switch PermissionPrompter.explainMissing(permission, feature: feature) {
        case .allowAgain:
            requestAgain(permission)
        case .turnOff:
            settingsStore.update { PermissionPolicy.disableFeature(needing: permission, in: &$0) }
        case .later:
            break
        }
    }

    /// 이전 서명의 항목을 지우고 새로 요청한 뒤 시스템 설정을 연다.
    private func requestAgain(_ permission: PermissionKind) {
        PermissionPrompter.resetStaleEntry(permission)
        switch permission {
        case .inputMonitoring: KeyboardMonitor.requestPermission()
        case .accessibility: AccessibilityFocusMonitor.requestTrust()
        }
        PermissionPrompter.openSettings(permission)
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputSourceMonitor.stop()
        capsLockMonitor.stop()
        appFocusMonitor.stop()
        keyboardMonitor.stop()
        focusMonitor.detach()
    }

    // MARK: - Store observers

    private func inputChanged(from old: InputSnapshot, to new: InputSnapshot) {
        Self.log.debug("caps=\(new.isCapsLockOn) source=\(new.source?.id ?? "-", privacy: .public)")
        overlay.apply(state: new.state, settings: settings)

        if isStarted, settings.showHUD, old.state != new.state {
            // 화면 위치는 앱 전환·Space 변경 때 계산해 둔 값을 쓴다(창 목록 조회로 표시가 늦어지지 않게).
            hud.show(color: settings.color(for: new.state), on: activeScreen)
        }

        // 앱별·창별 기억: 현재 활성 앱(창)에서 Source가 바뀔 때마다 기록한다.
        autoReset.sourceChanged(
            from: old.source,
            to: new.source,
            activeBundleID: appFocusMonitor.current?.bundleID,
            activeWindow: focusMonitor.currentWindow.map(AnyHashable.init)
        )
    }

    private func settingsChanged(from old: KeyHueSettings, to new: KeyHueSettings) {
        if old.appLanguage != new.appLanguage {
            // 재시작 없이 바로 적용: 메뉴는 다시 만들고, 설정 창(SwiftUI)은 settings 변경으로 다시 그려진다.
            Localization.apply(new.appLanguage)
            statusBar?.buildMenu()
            installMainMenu()
            settingsWindow?.updateTitle()
        }
        if old.showDockIcon != new.showDockIcon {
            applyDockIconPolicy()
        }
        if old.displayPolicy != new.displayPolicy || old.showHUD != new.showHUD {
            updateActiveScreen()
        }
        if new.showHUD, !old.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: new)
        if old.resetOnEscape != new.resetOnEscape {
            updateKeyboardMonitor()
        }
        if old.resetOnTextFocusLoss != new.resetOnTextFocusLoss
            || old.onWindowSwitch != new.onWindowSwitch {
            updateFocusMonitor()
        }
    }

    // MARK: - OS events

    private func appActivated(previous: AppFocusMonitor.ActiveApp?, current: AppFocusMonitor.ActiveApp) {
        autoReset.appActivated(
            previousBundleID: previous?.bundleID,
            currentBundleID: current.bundleID,
            sourceBeforeActivation: stateStore.snapshot.source,
            // 새 앱에 다시 붙기 전이라 아직 떠나는 앱의 메인 창이다.
            previousWindow: focusMonitor.currentWindow.map(AnyHashable.init),
            refresh: {
                resync()
                updateActiveScreen()
                updateKeyboardMonitor()
                updateFocusMonitor()
                return stateStore.snapshot.source
            },
            currentWindow: { focusMonitor.currentWindow.map(AnyHashable.init) }
        )
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

    private func updateFocusMonitor() {
        // 켜진 옵션에 필요한 알림·조회만 한다(텍스트 필드가 꺼져 있으면 포커스 변경은 구독하지 않는다).
        let use = settings.accessibilityUse
        if !use.isEmpty, let pid = appFocusMonitor.current?.pid {
            focusMonitor.attach(to: pid, for: use)
        } else {
            focusMonitor.detach()
        }
    }

    /// Dock 아이콘 클릭, Finder/Launchpad에서 다시 실행 → 설정 창을 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Dock 표시(regular) ↔ 메뉴바 전용(accessory). 재시작 없이 바로 바뀐다.
    private func applyDockIconPolicy() {
        let policy: NSApplication.ActivationPolicy = settings.showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // accessory로 바뀌면 앱이 비활성화되어 열려 있던 설정 창이 뒤로 숨는다.
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Dock에 보일 때 화면 상단에 나오는 앱 메뉴.
    private func installMainMenu() {
        guard let statusBar else { return }
        NSApp.mainMenu = MainMenu.make(
            target: statusBar,
            showSettings: #selector(StatusBarController.showSettings),
            showAbout: #selector(StatusBarController.showAbout)
        )
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
        // 메뉴를 열 때마다 재시도한다: 권한을 방금 허용했다면 여기서 시작된다.
        let isEnabled = settings.resetOnEscape
        return PermissionPolicy.status(isEnabled: isEnabled, isWorking: isEnabled && keyboardMonitor.start())
    }

    var textFocusResetStatus: FeatureStatus {
        accessibilityStatus(isEnabled: settings.resetOnTextFocusLoss)
    }

    var windowSwitchResetStatus: FeatureStatus {
        accessibilityStatus(isEnabled: settings.watchesWindowSwitches)
    }

    private func accessibilityStatus(isEnabled: Bool) -> FeatureStatus {
        let isWorking = isEnabled && AccessibilityFocusMonitor.isTrusted
        if isWorking { updateFocusMonitor() }
        return PermissionPolicy.status(isEnabled: isEnabled, isWorking: isWorking)
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

    func setOnWindowSwitch(_ behavior: SwitchBehavior) {
        if behavior != .keep, !AccessibilityFocusMonitor.isTrusted {
            let feature: PermissionPrompter.AccessibilityFeature = behavior == .restoreLast ? .windowMemory : .windowSwitch
            guard PermissionPrompter.explain(.accessibility, for: feature) else { return }
            AccessibilityFocusMonitor.requestTrust()
        }
        settingsStore.update { $0.onWindowSwitch = behavior }
    }

    func setResetOnTextFocusLoss(_ enabled: Bool) {
        if enabled, !AccessibilityFocusMonitor.isTrusted {
            guard PermissionPrompter.explain(.accessibility) else { return }
            AccessibilityFocusMonitor.requestTrust()
        }
        settingsStore.update { $0.resetOnTextFocusLoss = enabled }
    }

    func openInputMonitoringSettings() {
        requestAgain(.inputMonitoring)
    }

    func openAccessibilitySettings() {
        requestAgain(.accessibility)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            if enabled, LoginItemController.requiresApproval {
                LoginItemController.openSystemSettings()
            }
        } catch {
            PermissionPrompter.showError(L("Couldn't change Launch at Login"), error)
        }
    }

    func forgetPerAppInputs() {
        autoReset.forgetRememberedInputs()
    }

    func showSettings() {
        settingsWindow?.show()
    }
}
