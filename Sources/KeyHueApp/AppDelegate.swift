import AppKit
import KeyHueCore

/// Composition root.
///
///     macOS Events → Monitors → InputStateStore → Overlay / HUD / StatusBar
///                        ↘ AutoResetCoordinator(Core) → InputSourceController (기본 입력 소스로 전환)
///
/// UI 컴포넌트는 OS 이벤트를 직접 처리하지 않고 store의 변경만 구독한다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        appFocusMonitor.onWake = { [weak self] in
            Log.app.notice("wake")
            self?.resync()
        }
        appFocusMonitor.start()

        autoReset.onEvent = { [weak self] event in
            Log.state.notice("auto reset: \(event) now=\(InputSourceController.current()?.id ?? "-")")
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
            Log.state.notice("window switched within \(self.appFocusMonitor.current?.bundleID ?? "-")")
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
        settingsWindow?.onVisibilityChange = { [weak self] visible in
            self?.applyDockIconPolicy(settingsWindowOpen: visible)
        }
        installMainMenu()

        updateActiveScreen()
        if settings.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: settings)
        updateKeyboardMonitor()
        updateFocusMonitor()
        isStarted = true
        logLaunch()
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
        Log.app.notice("permission missing for enabled feature: \(permission.tccService)")

        let defaultName = InputSourceController.resolvedDefaultSource(preferredID: settings.defaultSourceID)?.displayName
            ?? StatusMenuState.fallbackSourceName
        let feature = switch permission {
        case .inputMonitoring: L("Switch to %@ on ESC", defaultName)
        case .accessibility where settings.watchesWindowSwitches:
            L("When Switching Windows in the Same App") + " › "
                + StatusBarController.title(for: settings.onWindowSwitch, defaultName: defaultName)
        case .accessibility: L("Switch to %@ When Leaving Text Field", defaultName)
        }
        let choice = PermissionPrompter.explainMissing(permission, feature: feature)
        Log.app.notice("missing permission \(permission.tccService): user chose \(String(describing: choice))")
        switch choice {
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

    /// 문제를 볼 때 "그때 어떤 버전·설정·권한이었나"를 알 수 있게 실행 시점의 상태를 남긴다(ADR 0036).
    private func logLaunch() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.app.notice("launch KeyHue \(version) (\(build)) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(Self.osBuild))")
        let changed = settings.nonDefaultDescriptions
        Log.app.notice("settings: \(changed.isEmpty ? "all default" : changed.joined(separator: ", "))")
        Log.app.notice(
            "permissions: inputMonitoring=\(KeyboardMonitor.hasPermission) accessibility=\(AccessibilityFocusMonitor.isTrusted)"
                + " macOSIndicatorHidden=\(SystemInputIndicator().isHidden)"
        )
        // 실행 직후에는 KeyHue 자신이 맨 앞인 경우가 많다(Dock 표시). 그때는 다음 앱 활성화부터 관찰한다.
        let front = appFocusMonitor.current?.bundleID ?? "KeyHue itself (observing starts at the next app activation)"
        Log.app.notice("front app: \(front) source: \(stateStore.snapshot.source?.id ?? "-")")
    }

    /// macOS 빌드 번호(예: 25G83). 현지화되지 않은 값.
    private static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("quit")
        Log.file?.flush()
        inputSourceMonitor.stop()
        capsLockMonitor.stop()
        appFocusMonitor.stop()
        keyboardMonitor.stop()
        focusMonitor.detach()
    }

    // MARK: - Store observers

    private func inputChanged(from old: InputSnapshot, to new: InputSnapshot) {
        Log.state.notice("caps=\(new.isCapsLockOn) source=\(new.source?.id ?? "-")")
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
        for change in KeyHueSettings.changeDescriptions(from: old, to: new) {
            Log.app.notice("setting \(change)")
        }
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
        Log.state.notice("app activated \(current.bundleID ?? "-") (pid \(current.pid))")
        autoReset.appActivated(
            previousBundleID: previous?.bundleID,
            currentBundleID: current.bundleID,
            sourceBeforeActivation: stateStore.snapshot.source,
            // 새 앱에 다시 붙기 전이라 아직 떠나는 앱의 메인 창이다.
            previousWindow: focusMonitor.currentWindow.map(AnyHashable.init),
            // 전환 시점(40 ms 뒤)에 읽는다. 그때는 아래에서 새 앱에 붙어 앞 창을 알고 있다.
            currentWindow: { [weak self] in self?.focusMonitor.currentWindow.map(AnyHashable.init) }
        )
        // 전환 예약을 먼저 걸고 나서 무거운 작업(AX 붙기, 창 목록 조회)을 한다. 예약 시간이 이 작업만큼 밀리지 않는다.
        resync()
        updateActiveScreen()
        updateKeyboardMonitor()
        updateFocusMonitor()
    }

    private func spaceChanged() {
        Log.state.debug("space changed")
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
    /// 설정 창이 닫힐 때는 창이 아직 보이는 상태로 불리므로, 열림 여부를 직접 받는다.
    private func applyDockIconPolicy(settingsWindowOpen: Bool? = nil) {
        let open = settingsWindowOpen ?? (settingsWindow?.isVisible ?? false)
        let policy: NSApplication.ActivationPolicy = settings.showsDockIcon(settingsWindowOpen: open) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if open {
            // 정책이 바뀌면 앱이 비활성화되어 열려 있던 설정 창이 뒤로 숨는다.
            NSApp.activate(ignoringOtherApps: true)
        } else if policy == .accessory {
            // 설정 창을 닫아 메뉴바 전용으로 돌아간다. 창 없는 KeyHue에 포커스가 남지 않게 원래 앱에 돌려준다(ADR 0038).
            NSApp.hide(nil)
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

    var windowSwitchStalledApp: String? {
        guard settings.watchesWindowSwitches,
              let pid = focusMonitor.stalledPID,
              pid == appFocusMonitor.current?.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? appFocusMonitor.current?.bundleID
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

    var isSystemInputIndicatorHidden: Bool {
        SystemInputIndicator().isHidden
    }

    func setSystemInputIndicatorHidden(_ hidden: Bool) {
        SystemInputIndicator().setHidden(hidden)
        Log.app.notice("macOS input source indicator \(hidden ? "hidden" : "shown")")
    }

    func forgetPerAppInputs() {
        autoReset.forgetRememberedInputs()
    }

    func showSettings() {
        settingsWindow?.show()
    }

    func showLogFile() {
        StatusBarController.showLogFile()
    }
}
