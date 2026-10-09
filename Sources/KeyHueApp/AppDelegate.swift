import AppKit
import Carbon
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
    private let updates = UpdateChecker()
    private let appMemory = AppInputMemory()

    private let inputSourceMonitor = InputSourceMonitor()
    private let capsLockMonitor = CapsLockMonitor()
    private let appFocusMonitor = AppFocusMonitor()
    private let inputMethodManager = InputMethodManager()
    private let permissions = PermissionFlow(gate: SystemPermissionGate())

    private let overlay = OverlayController()
    private let hud = HUDController()
    private lazy var warnings = WrongLanguageWarningPresenter(
        hud: hud, overlay: overlay,
        settings: { [unowned self] in self.settings },
        screen: { [unowned self] in ActiveScreenLocator.focusedScreen(activeAppScreen: self.activeScreen) }
    )
    private lazy var correctionFeedbackCoordinator = CorrectionFeedbackCoordinator(
        store: .shared,
        settings: { [unowned self] in self.settings },
        showNotice: { [weak self] title, caption in self?.warnings.showNotice(title: title, caption: caption) }
    )
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    private var activeScreen: NSScreen?
    private var isStarted = false

    private lazy var monitors: FeatureMonitors = FeatureMonitors(
        settings: { [unowned self] in self.settings },
        frontApp: { [unowned self] in self.appFocusMonitor.current }
    )

    private lazy var switching: InputSwitching = InputSwitching(
        memory: appMemory,
        settings: { [unowned self] in self.autoResetSettings },
        serverNeedsUpdate: { [unowned self] in self.inputMethodManager.status.needsUpdate },
        routingEnabled: { [unowned self] in
            self.settings.integrateInputMethod && self.settings.routeInputMethodPair
                && self.monitors.isKeyboardWorking
                && self.appFocusMonitor.current?.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
                && InputMethodIntegration.routesABC(frontBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                                    secureInput: IsSecureEventInputEnabled())
        }
    )

    private lazy var inputMethodLifecycle: InputMethodLifecycleCoordinator = InputMethodLifecycleCoordinator(
        manager: inputMethodManager,
        settingsStore: settingsStore,
        sessionRepair: switching.sessionRepair,
        autoReset: switching.autoReset,
        inputSourceMonitor: inputSourceMonitor,
        inputMethodRouter: switching.router,
        pauseIntegration: { [weak self] in self?.actions.pauseInputMethodIntegration() },
        refreshStatus: { [weak self] in self?.settingsWindow?.refreshInputMethodStatus() },
        promptToAddModes: { [weak self] in
            InputMethodSetup.promptToAddModes { self?.actions.openInputSourceSettings() }
        },
        selectHangulAfterSetup: { InputMethodSetup.selectHangulAfterSetup() },
        relaunch: { try InputMethodSetup.relaunch(finishSetup: $0) },
        reportFailure: { error in
            Log.app.error("input method management failed: \(String(describing: error))")
            PermissionPrompter.showError(L("Input Method Operation Failed"), error)
        }
    )

    private lazy var actions: AppActions = AppActions(
        settingsStore: settingsStore,
        permissions: permissions,
        monitors: monitors,
        switching: switching,
        inputSourceMonitor: inputSourceMonitor,
        inputMethodManager: inputMethodManager,
        inputMethodLifecycle: inputMethodLifecycle,
        settingsWindow: { [weak self] in self?.settingsWindow }
    )

    private var settings: KeyHueSettings { switching.displaySettings(settingsStore.settings) }

    private var autoResetSettings: KeyHueSettings {
        var result = settings
        if inputMethodLifecycle.isRunning {
            result.onAppSwitch = .keep
            result.onWindowSwitch = .keep
            result.resetOnEscape = false
            result.resetOnTextFocusLoss = false
        }
        return result
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // UI를 만들기 전에 앱 언어와 Dock 표시 여부를 적용한다.
        Localization.apply(settings.appLanguage)
        AppPresence.applyDockIconPolicy(settings: settings, settingsWindowOpen: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPresence.terminateIfAlreadyRunning() else { return }

        stateStore.addObserver { [weak self] old, new in self?.inputChanged(from: old, to: new) }
        settingsStore.addObserver { [weak self] old, new in self?.settingsChanged(from: old, to: new) }

        overlay.start()
        switching.start(inputSourceMonitor: inputSourceMonitor) { [weak self] in
            self?.settingsStore.update { $0.routeInputMethodPair = false }
        }
        inputSourceMonitor.onAvailabilityChange = { [weak self] in
            self?.switching.enabledSourcesChanged()
            self?.settingsWindow?.refreshInputMethodStatus()
        }
        inputSourceMonitor.start { [weak self] source in
            guard let self, !self.switching.sessionRepair.isRepairing else { return }
            self.stateStore.updateSource(source)
        }
        capsLockMonitor.start { [weak self] isOn in self?.stateStore.updateCapsLock(isOn) }

        appFocusMonitor.onAppActivated = { [weak self] previous, current in
            self?.appActivated(previous: previous, current: current)
        }
        appFocusMonitor.onSpaceChanged = { [weak self] in self?.spaceChanged() }
        appFocusMonitor.onActiveDisplayChanged = { [weak self] in self?.activeDisplayChanged() }
        appFocusMonitor.onWake = { [weak self] in
            Log.app.notice("wake")
            self?.resync()
            if let self { self.updates.configure(automatic: self.settings.automaticallyChecksForUpdates) }
        }
        appFocusMonitor.start()
        // Failures arrive with an app ID and a reason; undone corrections only as
        // "the file changed" (words never travel in distributed notifications, ADR 0065).
        correctionFeedbackCoordinator.start()
        // 모니터를 꽂거나 빼면 HUD·경고 메시지를 띄울 화면을 다시 구한다(빠진 모니터에 띄우지 않게).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActiveScreen() }
        }

        monitors.keyboard.onKeyDown = { [weak self] key in
            guard let self else { return }
            // 타이핑을 시작하면 HUD를 바로 숨긴다(어떤 키인지는 보지 않는다, ADR 0025).
            self.hud.hideNow()
            self.switching.keyDown(key, current: self.stateStore.snapshot.source)
            self.monitors.wrongLanguage.key(key, sourceID: self.stateStore.snapshot.source?.id)
        }
        monitors.keyboard.onMouseDown = { [weak self] in
            self?.switching.mouseDown()
            self?.monitors.wrongLanguage.reset()
        }
        monitors.wrongLanguage.onWarning = { [weak self] verdict, whileTyping in
            self?.warnings.show(verdict, whileTyping: whileTyping)
        }
        monitors.focus.onWindowSwitched = { [weak self] previous, window in
            guard let self else { return }
            Log.state.notice("window switched within \(self.appFocusMonitor.current?.bundleID ?? "-")")
            self.switching.windowSwitched(from: previous.map(AnyHashable.init), to: AnyHashable(window),
                                          current: self.stateStore.snapshot.source)
        }
        monitors.focus.onFocusChanged = { [weak self] wasText, isText in
            guard let self else { return }
            self.switching.focusChanged(wasTextInput: wasText, isTextInput: isText, current: self.stateStore.snapshot.source)
        }

        statusBar = StatusBarController(settingsStore: settingsStore, stateStore: stateStore, actions: actions, updates: updates,
                                        displaySettings: { [unowned self] in self.settings })
        settingsWindow = SettingsWindowController(model: SettingsModel(store: settingsStore, actions: actions, updates: updates))
        settingsWindow?.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            AppPresence.applyDockIconPolicy(settings: self.settings, settingsWindowOpen: visible)
        }
        AppPresence.installMainMenu(statusBar: statusBar, updates: updates)
        updates.addObserver { [weak self] in AppPresence.installMainMenu(statusBar: self?.statusBar, updates: self?.updates) }
        updates.configure(automatic: settings.automaticallyChecksForUpdates)

        updateActiveScreen()
        if settings.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: settings)
        monitors.update()
        isStarted = true
        if CommandLine.arguments.contains(WorkerCommand.finishSetupFlag) {
            switching.finishSetupAfterRelaunch(inputSourceMonitor: inputSourceMonitor)
        }
        LaunchDiagnostics.log(settings: settings, ignoredKeys: settingsStore.ignoredKeys,
                              frontBundleID: appFocusMonitor.current?.bundleID, sourceID: stateStore.snapshot.source?.id,
                              inputMethod: inputMethodManager.status)
        // 입력기 설치 직후의 재실행: 방금 설명하고 요청한 권한을 "끊겼다"고 다시 알리지 않는다(ADR 0084).
        guard !CommandLine.arguments.contains(WorkerCommand.relaunchedFlag) else {
            Log.app.notice("permission check skipped: relaunched after input method setup")
            return
        }
        // 메뉴바가 자리 잡은 뒤, 켜 둔 기능의 권한이 끊겼는지 확인한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.warnIfPermissionMissing() }
        }
    }

    /// ESC/텍스트 필드/창 전환을 켜 두었는데 권한이 없으면 한 번 알린다(업데이트·재빌드 뒤 흔하다).
    private func warnIfPermissionMissing() {
        let defaultName = InputMethodIntegration.defaultSource(settings: settings, sources: InputSourceController.enabledSources())?.displayName
            ?? L("Default Input Source")
        let result = permissions.warnIfMissing(settings: settings, defaultName: defaultName) { permission in
            settingsStore.update { PermissionPolicy.disableFeature(needing: permission, in: &$0) }
        }
        if let (permission, choice) = result {
            Log.app.notice("missing permission \(permission.tccService): user chose \(String(describing: choice))")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.configure(automatic: false)
        Log.app.notice("quit")
        Log.file?.flush()
        inputSourceMonitor.stop()
        switching.stop()
        capsLockMonitor.stop()
        appFocusMonitor.stop()
        monitors.stop()
    }

    // MARK: - Store observers

    private func inputChanged(from old: InputSnapshot, to new: InputSnapshot) {
        Log.state.notice("caps=\(new.isCapsLockOn) source=\(new.source?.id ?? "-")")
        overlay.apply(state: new.state, settings: settings)

        if old.source != new.source {
            // 경고를 보고 입력 소스를 바꿨다: 메시지는 할 일을 다 했다(전환 HUD와 같은 자리라 겹치지 않게 바로 숨긴다).
            warnings.hideNow()
        }
        if isStarted, settings.showHUD, old.state != new.state {
            // 포커스가 있는 화면을 표시 순간에 구한다. 창 목록은 조회하지 않는다(ADR 0024, 0063).
            hud.show(color: settings.color(for: new.state), on: ActiveScreenLocator.focusedScreen(activeAppScreen: activeScreen))
        }
        Log.state.notice("display bar=\(overlay.diagnostics) hud=\(hud.diagnostics)")

        switching.sourceChanged(from: old.source, to: new.source, activeBundleID: appFocusMonitor.current?.bundleID,
                                activeWindow: monitors.focus.currentWindow.map(AnyHashable.init))
    }

    private func settingsChanged(from old: KeyHueSettings, to new: KeyHueSettings) {
        switching.settingsChanged(from: old, to: new)
        for change in KeyHueSettings.changeDescriptions(from: old, to: new) {
            Log.app.notice("setting \(change)")
        }
        if old.inputMethodCorrection != new.inputMethodCorrection || old.correctionExcludedApps != new.correctionExcludedApps
            || old.correctionIgnoredWords != new.correctionIgnoredWords || old.recordUndoneCorrections != new.recordUndoneCorrections
            || old.correctionShortcut != new.correctionShortcut {
            // The input method is a separate process: it re-reads the stored values (ADR 0064).
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(InputMethodCorrection.settingsChanged), object: nil, userInfo: nil, deliverImmediately: true)
        }
        if old.automaticallyChecksForUpdates != new.automaticallyChecksForUpdates {
            updates.configure(automatic: new.automaticallyChecksForUpdates)
        }
        if old.appLanguage != new.appLanguage {
            // 재시작 없이 바로 적용: 메뉴는 다시 만들고, 설정 창(SwiftUI)은 settings 변경으로 다시 그려진다.
            Localization.apply(new.appLanguage)
            statusBar?.buildMenu()
            AppPresence.installMainMenu(statusBar: statusBar, updates: updates)
            settingsWindow?.updateTitle()
        }
        if old.showDockIcon != new.showDockIcon {
            AppPresence.applyDockIconPolicy(settings: new, settingsWindowOpen: settingsWindow?.isVisible ?? false)
        }
        if old.followsActiveScreen != new.followsActiveScreen || old.displayPolicy != new.displayPolicy {
            updateActiveScreen()
        }
        if new.showHUD, !old.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: switching.displaySettings(new))
        if old.watchesKeyboard != new.watchesKeyboard || old.warnOnWrongLanguage != new.warnOnWrongLanguage
            || old.routeInputMethodPair != new.routeInputMethodPair || old.integrateInputMethod != new.integrateInputMethod {
            monitors.updateKeyboard()
        }
        if old.resetOnTextFocusLoss != new.resetOnTextFocusLoss
            || old.onWindowSwitch != new.onWindowSwitch {
            monitors.updateFocus()
        }
    }

    // MARK: - OS events

    private func appActivated(previous: AppFocusMonitor.ActiveApp?, current: AppFocusMonitor.ActiveApp) {
        switching.router.reset(current: InputSourceController.current())
        Log.state.notice("app activated \(current.bundleID ?? "-") (pid \(current.pid))")
        switching.autoReset.appActivated(
            previousBundleID: previous?.bundleID,
            currentBundleID: current.bundleID,
            sourceBeforeActivation: stateStore.snapshot.source,
            // 새 앱에 다시 붙기 전이라 아직 떠나는 앱의 메인 창이다.
            previousWindow: monitors.focus.currentWindow.map(AnyHashable.init),
            // 전환 시점(40 ms 뒤)에 읽는다. 그때는 아래에서 새 앱에 붙어 앞 창을 알고 있다.
            currentWindow: { [weak self] in self?.monitors.focus.currentWindow.map(AnyHashable.init) }
        )
        // 전환 예약을 먼저 걸고 나서 무거운 작업(AX 붙기, 창 목록 조회)을 한다. 예약 시간이 이 작업만큼 밀리지 않는다.
        monitors.wrongLanguage.reset()
        resync()
        updateActiveScreen()
        monitors.update()
    }

    private func spaceChanged() {
        switching.router.reset(current: InputSourceController.current())
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

    private func updateActiveScreen() {
        guard settings.followsActiveScreen else {
            // 따라가지 않는 동안의 값은 낡는다(모니터를 뺐을 수도 있다). 다시 켜면 새로 구한다.
            activeScreen = nil
            return
        }
        activeScreen = ActiveScreenLocator.screen(forPID: appFocusMonitor.current?.pid)
        overlay.setActiveScreen(ActiveScreenLocator.focusedScreen(activeAppScreen: activeScreen))
    }

    /// 포커스가 다른 모니터로 옮겨졌다(같은 앱의 다른 모니터 창 포함, ADR 0063). 창 목록은 조회하지 않는다.
    private func activeDisplayChanged() {
        guard settings.followsActiveScreen else { return }
        overlay.setActiveScreen(ActiveScreenLocator.focusedScreen(activeAppScreen: activeScreen))
    }

    /// Dock 아이콘 클릭, Finder/Launchpad에서 다시 실행 → 설정 창을 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        actions.showSettings()
        return false
    }
}
