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
    private let updates = UpdateChecker()
    private let appMemory = AppInputMemory()

    private let inputSourceMonitor = InputSourceMonitor()
    private let capsLockMonitor = CapsLockMonitor()
    private let appFocusMonitor = AppFocusMonitor()
    private let keyboardMonitor = KeyboardMonitor()
    private let focusMonitor = AccessibilityFocusMonitor()
    private let wrongLanguage = WrongLanguageMonitor()
    private let inputMethodManager = InputMethodManager()
    private let acknowledgementMonitor = InputMethodAcknowledgementMonitor()
    private let shortcutPoster = InputSourceShortcutPoster()
    private let permissions = PermissionFlow(gate: SystemPermissionGate())
    private var inputMethodOperationRunning = false

    private let overlay = OverlayController()
    private let hud = HUDController()
    private let wrongLanguageToast = WrongLanguageToast()
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    private var activeScreen: NSScreen?
    private var isStarted = false

    /// KeyHue 자신의 선택은 모두 이 전환기를 거친다. KeyHue 모드를 고르면 입력기 세션 확인을 시작한다(ADR 0062).
    private lazy var switcher: SystemInputSourceSwitcher = {
        let switcher = SystemInputSourceSwitcher()
        switcher.onSelected = { [unowned self] selected, previous in
            self.sessionRepair.selected(sourceID: selected, previousID: previous)
        }
        return switcher
    }()

    /// 외부 선택은 세션 없는 앱에 입력기 세션을 만들지 않는다(ADR 0061). 확인이 없으면 사용자의 이전 입력 소스 단축키를 두 번 누른다.
    private lazy var sessionRepair = SystemSessionRepair.make(poster: shortcutPoster)

    /// 자동 전환의 "언제·재시도" 판단은 Core에 있다(테스트 대상). 여기서는 실제 TIS와 main queue를 연결한다.
    private lazy var autoReset = AutoResetCoordinator(
        switcher: switcher,
        scheduler: MainQueueScheduler(),
        memory: appMemory,
        settings: { [unowned self] in self.autoResetSettings }
    )

    private lazy var inputMethodRouter = InputMethodRoutingCoordinator(
        switcher: switcher, scheduler: MainQueueScheduler(),
        isEnabled: { [unowned self] in
            self.settings.integrateInputMethod && self.settings.routeInputMethodPair
                && KeyboardMonitor.hasPermission && self.keyboardMonitor.isRunning
                && self.appFocusMonitor.current?.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    )

    private var settings: KeyHueSettings { settingsStore.settings }

    private var autoResetSettings: KeyHueSettings {
        var result = settings
        if inputMethodOperationRunning {
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
        applyDockIconPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

        stateStore.addObserver { [weak self] old, new in self?.inputChanged(from: old, to: new) }
        settingsStore.addObserver { [weak self] old, new in self?.settingsChanged(from: old, to: new) }

        overlay.start()
        inputMethodRouter.reset(current: InputSourceController.current())
        inputMethodRouter.onRequest = { [weak self] in self?.autoReset.cancelPendingWork() }
        inputMethodRouter.onCompletion = { [weak self] ok in
            Log.state.notice("input method routing: \(ok ? "ok" : "FAILED")")
            self?.inputSourceMonitor.refresh()
        }
        inputMethodRouter.onSuspend = { [weak self] in
            Log.state.notice("input method routing suspended: selection failed or immediately overwritten")
            self?.settingsStore.update { $0.routeInputMethodPair = false }
        }
        inputSourceMonitor.onSelection = { [weak self] source in
            // 복구 단축키 사이의 중간 소스는 사용자의 선택이 아니다.
            guard let self, !self.sessionRepair.isRepairing else { return }
            self.inputMethodRouter.sourceChanged(to: source)
        }
        sessionRepair.onRepairStarted = { [weak self] in
            Log.state.notice("input method session not acknowledged; pressing the previous-source shortcut twice")
            self?.autoReset.cancelPendingWork()
        }
        sessionRepair.onFinished = { [weak self] outcome in
            guard let self, outcome != .acknowledged else { return }
            Log.state.notice("input method session repair: \(String(describing: outcome)) now=\(InputSourceController.current()?.id ?? "-")")
            self.inputMethodRouter.reset(current: InputSourceController.current())
            self.inputSourceMonitor.refresh()
        }
        acknowledgementMonitor.start { [weak self] modeID in
            self?.sessionRepair.acknowledged(modeID: modeID)
        }
        inputSourceMonitor.onAvailabilityChange = { [weak self] in
            self?.inputMethodRouter.reset(current: InputSourceController.current())
            self?.settingsWindow?.refreshInputMethodStatus()
        }
        autoReset.onWillSwitch = { [weak self] in
            // Source notifications caused by KeyHue aren't manual toggle requests.
            self?.inputMethodRouter.reset(current: nil)
        }
        inputSourceMonitor.start { [weak self] source in
            guard let self, !self.sessionRepair.isRepairing else { return }
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
        // 모니터를 꽂거나 빼면 HUD·경고 메시지를 띄울 화면을 다시 구한다(빠진 모니터에 띄우지 않게).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActiveScreen() }
        }

        autoReset.onEvent = { [weak self] event in
            Log.state.notice("auto reset: \(event) now=\(InputSourceController.current()?.id ?? "-")")
            switch event {
            case .switched:
                self?.inputMethodRouter.reset(current: InputSourceController.current())
                self?.inputSourceMonitor.refresh()
            case .retrying, .skipped, .keptManualSwitch: break
            }
        }
        keyboardMonitor.onKeyDown = { [weak self] key in
            guard let self else { return }
            // 타이핑을 시작하면 HUD를 바로 숨긴다(어떤 키인지는 보지 않는다, ADR 0025).
            self.hud.hideNow()
            self.sessionRepair.interaction()
            self.inputMethodRouter.interaction(isTyping: !key.otherModifiers)
            // ⌘Space·⌃Space 같은 단축키는 입력 소스를 바꿀 수 있다. 앱 전환 대기 중이면 그 결과를 사용자 선택으로 본다.
            if key.otherModifiers { self.autoReset.userMayHaveSwitchedSource() }
            self.autoReset.keyDown(keyCode: key.keyCode, isAutoRepeat: key.isAutoRepeat, current: self.stateStore.snapshot.source)
            self.wrongLanguage.key(key, sourceID: self.stateStore.snapshot.source?.id)
        }
        keyboardMonitor.onMouseDown = { [weak self] in
            self?.autoReset.userMayHaveSwitchedSource() // 메뉴 막대 입력 메뉴에서 고를 수 있다
            self?.wrongLanguage.reset()
            self?.sessionRepair.interaction()
            self?.inputMethodRouter.interaction(isTyping: false)
        }
        wrongLanguage.onWarning = { [weak self] verdict, whileTyping in
            self?.showWrongLanguageWarning(verdict, whileTyping: whileTyping)
        }
        focusMonitor.onWindowSwitched = { [weak self] previous, window in
            guard let self else { return }
            self.inputMethodRouter.reset(current: InputSourceController.current())
            Log.state.notice("window switched within \(self.appFocusMonitor.current?.bundleID ?? "-")")
            self.autoReset.windowSwitched(
                from: previous.map(AnyHashable.init),
                to: AnyHashable(window),
                current: self.stateStore.snapshot.source
            )
        }
        focusMonitor.onFocusChanged = { [weak self] wasText, isText in
            guard let self else { return }
            self.inputMethodRouter.reset(current: InputSourceController.current())
            self.autoReset.focusChanged(wasTextInput: wasText, isTextInput: isText, current: self.stateStore.snapshot.source)
        }

        statusBar = StatusBarController(settingsStore: settingsStore, stateStore: stateStore, actions: self, updates: updates)
        settingsWindow = SettingsWindowController(model: SettingsModel(store: settingsStore, actions: self, updates: updates))
        settingsWindow?.onVisibilityChange = { [weak self] visible in
            self?.applyDockIconPolicy(settingsWindowOpen: visible)
        }
        installMainMenu()
        updates.addObserver { [weak self] in self?.installMainMenu() }
        updates.configure(automatic: settings.automaticallyChecksForUpdates)

        updateActiveScreen()
        if settings.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: settings)
        updateKeyboardMonitor()
        updateFocusMonitor()
        isStarted = true
        if CommandLine.arguments.contains(WorkerCommand.finishSetupFlag), settings.integrateInputMethod,
           InputMethodIntegration.isAvailable(in: InputSourceController.enabledSources()) {
            let selected = InputSourceController.select(sourceID: InputMethodIntegration.hangulID)
            inputMethodRouter.reset(current: InputSourceController.current())
            inputSourceMonitor.refresh()
            Log.app.notice("input method setup after relaunch: selected=\(selected) observed=\(InputSourceController.current()?.id ?? "none")")
        }
        logLaunch()
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

    /// 문제를 볼 때 "그때 어떤 버전·설정·권한이었나"를 알 수 있게 실행 시점의 상태를 남긴다(ADR 0036).
    private func logLaunch() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.app.notice("launch KeyHue \(version) (\(build)) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(Self.osBuild))")
        let changed = settings.nonDefaultDescriptions
        Log.app.notice("settings: \(changed.isEmpty ? "all default" : changed.joined(separator: ", "))")
        if !settingsStore.ignoredKeys.isEmpty {
            // 형식이 깨진 값은 기본값으로 읽고 지웠다(ADR 0043). 키 이름만 남긴다.
            Log.app.error("settings: ignored corrupt values for \(settingsStore.ignoredKeys.joined(separator: ", "))")
        }
        Log.app.notice(
            "permissions: inputMonitoring=\(KeyboardMonitor.hasPermission) accessibility=\(AccessibilityFocusMonitor.isTrusted)"
                + " macOSIndicatorHidden=\(SystemInputIndicator().isHidden)"
        )
        // 실행 직후에는 KeyHue 자신이 맨 앞인 경우가 많다(Dock 표시). 그때는 다음 앱 활성화부터 관찰한다.
        let front = appFocusMonitor.current?.bundleID ?? "KeyHue itself (observing starts at the next app activation)"
        Log.app.notice("front app: \(front) source: \(stateStore.snapshot.source?.id ?? "-")")
        let inputMethod = inputMethodManager.status
        if inputMethod.isInstalled || inputMethod.hasRegisteredSources {
            let snapshot = InputSourceController.freshSnapshot()
            Log.app.notice("input method launch state installed=\(inputMethod.isInstalled) needsUpdate=\(inputMethod.needsUpdate) \(snapshot?.logDescription ?? "diagnostic unavailable")")
        }
    }

    /// macOS 빌드 번호(예: 25G83). 현지화되지 않은 값.
    private static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.configure(automatic: false)
        Log.app.notice("quit")
        Log.file?.flush()
        inputSourceMonitor.stop()
        acknowledgementMonitor.stop()
        capsLockMonitor.stop()
        appFocusMonitor.stop()
        keyboardMonitor.stop()
        focusMonitor.detach()
    }

    // MARK: - Store observers

    private func inputChanged(from old: InputSnapshot, to new: InputSnapshot) {
        Log.state.notice("caps=\(new.isCapsLockOn) source=\(new.source?.id ?? "-")")
        overlay.apply(state: new.state, settings: settings)

        if old.source != new.source {
            // 경고를 보고 입력 소스를 바꿨다: 메시지는 할 일을 다 했다(전환 HUD와 같은 자리라 겹치지 않게 바로 숨긴다).
            wrongLanguageToast.hideNow()
        }
        if isStarted, settings.showHUD, old.state != new.state {
            // 포커스가 있는 화면을 표시 순간에 구한다. 창 목록은 조회하지 않는다(ADR 0024, 0063).
            hud.show(color: settings.color(for: new.state), on: ActiveScreenLocator.focusedScreen(activeAppScreen: activeScreen))
        }

        // 앱별·창별 기억: 현재 활성 앱(창)에서 Source가 바뀔 때마다 기록한다.
        if !inputMethodRouter.isPending {
            autoReset.sourceChanged(
                from: old.source,
                to: new.source,
                activeBundleID: appFocusMonitor.current?.bundleID,
                activeWindow: focusMonitor.currentWindow.map(AnyHashable.init)
            )
        }
    }

    private func settingsChanged(from old: KeyHueSettings, to new: KeyHueSettings) {
        if old.integrateInputMethod != new.integrateInputMethod || old.routeInputMethodPair != new.routeInputMethodPair
            || old.defaultSourceID != new.defaultSourceID {
            autoReset.cancelPendingWork()
            inputMethodRouter.reset(current: InputSourceController.current())
        }
        for change in KeyHueSettings.changeDescriptions(from: old, to: new) {
            Log.app.notice("setting \(change)")
        }
        if old.automaticallyChecksForUpdates != new.automaticallyChecksForUpdates {
            updates.configure(automatic: new.automaticallyChecksForUpdates)
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
        if old.followsActiveScreen != new.followsActiveScreen || old.displayPolicy != new.displayPolicy {
            updateActiveScreen()
        }
        if new.showHUD, !old.showHUD {
            hud.prepare()
        }
        overlay.apply(state: stateStore.state, settings: new)
        if old.watchesKeyboard != new.watchesKeyboard || old.warnOnWrongLanguage != new.warnOnWrongLanguage
            || old.routeInputMethodPair != new.routeInputMethodPair || old.integrateInputMethod != new.integrateInputMethod {
            updateKeyboardMonitor()
        }
        if old.resetOnTextFocusLoss != new.resetOnTextFocusLoss
            || old.onWindowSwitch != new.onWindowSwitch {
            updateFocusMonitor()
        }
    }

    // MARK: - OS events

    private func appActivated(previous: AppFocusMonitor.ActiveApp?, current: AppFocusMonitor.ActiveApp) {
        inputMethodRouter.reset(current: InputSourceController.current())
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
        wrongLanguage.reset()
        resync()
        updateActiveScreen()
        updateKeyboardMonitor()
        updateFocusMonitor()
    }

    private func spaceChanged() {
        inputMethodRouter.reset(current: InputSourceController.current())
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

    private func updateKeyboardMonitor() {
        wrongLanguage.setEnabled(settings.warnOnWrongLanguage)
        if settings.watchesKeyboard {
            keyboardMonitor.start(observeMouse: settings.warnOnWrongLanguage || (settings.integrateInputMethod && settings.routeInputMethodPair))
        } else {
            keyboardMonitor.stop()
        }
    }

    /// 잘못된 언어 경고: 그 언어의 색으로 막대를 깜빡이고, "메시지로 알리기"가 켜져 있으면 바꾼 단어를 메시지로 띄운다(ADR 0041).
    /// 치는 중에 알렸으면(ADR 0042) 그때까지 친 앞부분에 "…"를 붙인다.
    private func showWrongLanguageWarning(_ verdict: MistypeVerdict, whileTyping: Bool) {
        let sources = InputSourceController.enabledSources()
        let integrated = settings.integrateInputMethod && InputMethodIntegration.isAvailable(in: sources)
        guard let id = MistypeSupport.intendedSourceID(for: verdict, enabledSourceIDs: sources.map(\.id), integrated: integrated),
              let source = sources.first(where: { $0.id == id }) else { return }
        let word: String
        switch verdict {
        case .keep: return
        case .meantHangul(let text), .meantLatin(let text): word = whileTyping ? text + "…" : text
        }
        let color = settings.color(for: source)
        if settings.wrongLanguageShowsMessage {
            hud.hideNow()
            wrongLanguageToast.show(
                word: word,
                sourceName: source.displayName,
                color: color,
                on: ActiveScreenLocator.focusedScreen(activeAppScreen: activeScreen)
            )
        }
        overlay.flash(color: color) // 막대를 숨겨 두었으면 아무것도 하지 않는다
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
            showAbout: #selector(StatusBarController.showAbout),
            updates: updates,
            checkUpdates: #selector(StatusBarController.updateAction)
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
        return PermissionPolicy.status(
            isEnabled: isEnabled,
            isWorking: isEnabled && keyboardMonitor.start(observeMouse: settings.warnOnWrongLanguage || (settings.integrateInputMethod && settings.routeInputMethodPair))
        )
    }

    var isWrongLanguageModelMissing: Bool {
        settings.warnOnWrongLanguage && wrongLanguage.isModelMissing
    }

    var wrongLanguageStatus: FeatureStatus {
        let isEnabled = settings.warnOnWrongLanguage
        return PermissionPolicy.status(
            isEnabled: isEnabled,
            isWorking: isEnabled && keyboardMonitor.start(observeMouse: true)
        )
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

    var inputMethodInstallationStatus: InputMethodInstallationStatus { inputMethodManager.status }
    var isInputMethodOperationRunning: Bool { inputMethodOperationRunning }

    func setInputMethodEnabled(_ enabled: Bool) {
        guard !inputMethodOperationRunning else { return }
        if enabled { installInputMethod() } else { pauseInputMethodIntegration() }
    }

    func installInputMethod() {
        guard !inputMethodOperationRunning else { return }
        // Choosing the integrated input method also chooses the two-mode setup.
        // Explain its optional system permission before changing files or sources.
        guard permissions.allowEnabling(.inputMonitoring(.inputMethodRouting)) else { return }
        manageInputMethod(removing: false)
    }

    func uninstallInputMethod() {
        guard !inputMethodOperationRunning else { return }
        manageInputMethod(removing: true)
    }

    private func manageInputMethod(removing: Bool) {
        inputMethodOperationRunning = true
        // The utility must not restore an IMK mode during an awaited file operation.
        pauseInputMethodIntegration()
        settingsWindow?.refreshInputMethodStatus()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.inputMethodOperationRunning = false
                self.settingsWindow?.refreshInputMethodStatus()
            }
            do {
                var finishSetup = false
                if removing {
                    try await self.inputMethodManager.uninstall()
                    self.settingsStore.update { $0.routeInputMethodPair = false }
                    Log.app.notice("input method removed")
                } else {
                    let ready = try await self.inputMethodManager.install()
                    // Preserve the user's setup request until they add both modes
                    // in System Settings. Availability gates routing and defaults.
                    self.settingsStore.update {
                        $0.integrateInputMethod = true
                        $0.routeInputMethodPair = true
                    }
                    if ready {
                        self.autoReset.cancelPendingWork()
                        finishSetup = true
                        Log.app.notice("bundled input method installed; both modes already added")
                    } else {
                        let alert = NSAlert()
                        alert.messageText = L("Input Method Installed")
                        alert.informativeText = L("Installation is complete. In System Settings → Keyboard → Text Input → Edit → +, add KeyHue Korean and English. Integration starts when both modes are enabled; you do not need to turn this option on again.")
                        alert.addButton(withTitle: L("Open Input Source Settings"))
                        alert.addButton(withTitle: L("Later"))
                        Log.app.notice("bundled input method installed; waiting for both modes to be enabled")
                        if alert.runModal() == .alertFirstButtonReturn { self.openInputSourceSettings() }
                    }
                }
                self.inputSourceMonitor.refresh()
                if InputMethodSourcePreferences.shared.isSupported && self.inputMethodManager.requiresRelaunch {
                    try self.relaunchAfterInputMethodOperation(finishSetup: finishSetup)
                } else if finishSetup {
                    guard InputSourceController.select(sourceID: InputMethodIntegration.hangulID) else { throw InputMethodManagementError.systemFailure }
                    self.inputMethodRouter.reset(current: InputSourceController.current())
                    self.inputSourceMonitor.refresh()
                }
            } catch {
                // Keep routing off on failure so ABC remains a usable escape.
                self.pauseInputMethodIntegration()
                self.inputSourceMonitor.refresh()
                Log.app.error("input method management failed: \(String(describing: error))")
                PermissionPrompter.showError(L("Input Method Operation Failed"), error)
            }
        }
    }

    private func relaunchAfterInputMethodOperation(finishSetup: Bool) throws {
        guard let executable = Bundle.main.executableURL else { throw InputMethodManagementError.systemFailure }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = WorkerCommand.relaunchArguments(parentPID: ProcessInfo.processInfo.processIdentifier, finishSetup: finishSetup)
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        _ = UserDefaults.standard.synchronize()
        try helper.run()
        Log.app.notice("relaunching KeyHue to refresh input source registration")
        NSApplication.shared.terminate(nil)
    }

    var inputMethodRoutingStatus: FeatureStatus {
        let enabled = settings.integrateInputMethod && settings.routeInputMethodPair
            && InputMethodIntegration.isAvailable(in: InputSourceController.enabledSources())
        return PermissionPolicy.status(isEnabled: enabled,
                                       isWorking: enabled && keyboardMonitor.start(observeMouse: true))
    }

    func openInputSourceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func setInputMethodRouting(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.inputMonitoring(.inputMethodRouting)) else { return }
        settingsStore.update { $0.routeInputMethodPair = enabled }
    }

    func pauseInputMethodIntegration() {
        // Change settings first so subsequent notifications cannot redirect ABC.
        settingsStore.update { $0.integrateInputMethod = false }
        autoReset.cancelPendingWork()
        inputMethodRouter.reset(current: nil)
        let ok = InputMethodSourcePreferences.shared.isSupported
            ? InputSourceController.selectFresh(sourceID: InputMethodIntegration.abcID)
            : InputSourceController.select(sourceID: InputMethodIntegration.abcID)
        inputMethodRouter.reset(current: InputSourceController.current())
        inputSourceMonitor.refresh()
        Log.state.notice("input method integration paused; ABC selection \(ok ? "ok" : "FAILED")")
        if !ok {
            let alert = NSAlert()
            alert.messageText = L("Integration Paused")
            alert.informativeText = L("ABC could not be selected. Choose an available input source from the macOS input menu.")
            alert.runModal()
        }
    }

    func setResetOnEscape(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.inputMonitoring(.escape)) else { return }
        settingsStore.update { $0.resetOnEscape = enabled }
    }

    func setWarnOnWrongLanguage(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.inputMonitoring(.wrongLanguage)) else { return }
        settingsStore.update { $0.warnOnWrongLanguage = enabled }
    }

    func setOnWindowSwitch(_ behavior: SwitchBehavior) {
        let feature: PermissionPrompter.AccessibilityFeature = behavior == .restoreLast ? .windowMemory : .windowSwitch
        guard behavior == .keep || permissions.allowEnabling(.accessibility(feature)) else { return }
        settingsStore.update { $0.onWindowSwitch = behavior }
    }

    func setResetOnTextFocusLoss(_ enabled: Bool) {
        guard !enabled || permissions.allowEnabling(.accessibility(.textFocus)) else { return }
        settingsStore.update { $0.resetOnTextFocusLoss = enabled }
    }

    func openInputMonitoringSettings() {
        permissions.requestAgain(.inputMonitoring)
    }

    func openAccessibilitySettings() {
        permissions.requestAgain(.accessibility)
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

    func showUpdates() {
        settingsWindow?.showUpdates()
    }

    func showSettings() {
        settingsWindow?.show()
    }

    func showLogFile() {
        StatusBarController.showLogFile()
    }
}
