import AppKit
import KeyHueCore

/// 메뉴바 UI. 상태는 InputStateStore / SettingsStore에서만 읽는다.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settingsStore: SettingsStore
    private let stateStore: InputStateStore
    private let updates: UpdateChecker
    private weak var actions: StatusMenuActions?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// Internal for tests: the rebuilt menu must keep every item.
    let menu = NSMenu()

    /// Settings, About and Check for Updates, shared with the app menu.
    let commands: AppMenuCommands
    private let updateItem = NSMenuItem(title: "", action: #selector(AppMenuCommands.checkForUpdates), keyEquivalent: "")
    private let currentInputItem = NSMenuItem()
    private let showBarItem = NSMenuItem(title: "", action: #selector(toggleShowBar), keyEquivalent: "")
    private let appSwitchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let escapeItem = NSMenuItem(title: "", action: #selector(toggleEscape), keyEquivalent: "")
    private let escapePermissionItem = NSMenuItem(title: "", action: #selector(openInputMonitoring), keyEquivalent: "")
    private let windowSwitchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let windowSwitchPermissionItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    /// "〈맨 앞 앱〉에서 창마다 기억"(ADR 0089). 메뉴를 열 때의 앱을 기억해 두고 그 앱을 넣거나 뺀다.
    private let windowMemoryAppItem = NSMenuItem(title: "", action: #selector(toggleWindowMemoryApp), keyEquivalent: "")
    private var windowMemoryApp: FrontApp?
    private let windowSwitchStalledItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // ADR 0069: the input method is one submenu: status, the next step, rare actions.
    private let inputMethodItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let inputMethodStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let nextStepItem = NSMenuItem(title: "", action: #selector(performNextStep), keyEquivalent: "")
    private let routingItem = NSMenuItem(title: "", action: #selector(toggleRouting), keyEquivalent: "")
    private let routingPermissionItem = NSMenuItem(title: "", action: #selector(openInputMonitoring), keyEquivalent: "")
    private let recoveryItem = NSMenuItem(title: "", action: #selector(pauseIntegration), keyEquivalent: "")
    private let uninstallInputMethodItem = NSMenuItem(title: "", action: #selector(uninstallInputMethod), keyEquivalent: "")
    private let inputMethodSettingsItem = NSMenuItem(title: "", action: #selector(showInputMethodSettings), keyEquivalent: "")
    private var nextStep: InputMethodMenuState.NextStep?

    private let icon = StatusItemIcon()

    /// Colors as shown: detours gray while integrated (ADR 0082).
    private let displaySettings: @MainActor () -> KeyHueSettings

    /// - Parameter displaySettings: required: the saved settings lack the gray of the detours.
    init(settingsStore: SettingsStore, stateStore: InputStateStore, actions: StatusMenuActions, updates: UpdateChecker = UpdateChecker(),
         displaySettings: @escaping @MainActor () -> KeyHueSettings) {
        self.settingsStore = settingsStore
        self.displaySettings = displaySettings
        self.stateStore = stateStore
        self.updates = updates
        self.actions = actions
        commands = AppMenuCommands(updates: updates, actions: actions)
        super.init()
        buildMenu()
        updates.addObserver { [weak self] in self?.refreshUpdateItem() }

        stateStore.addObserver { [weak self] _, _ in
            self?.updateCurrentInput()
            self?.updateStatusIcon()
        }
        settingsStore.addObserver { [weak self] _, _ in
            self?.updateCurrentInput()
            self?.updateStatusIcon()
        }
    }

    // MARK: - Build

    /// 언어를 바꾸면 다시 호출해 메뉴 전체를 새 언어로 만든다.
    func buildMenu() {
        statusItem.button?.toolTip = "KeyHue"
        updateStatusIcon()

        // 다시 만들 때 재사용하는 항목은 이전 하위 메뉴에서도 빼야 한다. NSMenu는 다른 메뉴에 든 항목을 받지 않는다.
        inputMethodItem.submenu?.removeAllItems()
        menu.removeAllItems()
        menu.delegate = self
        menu.autoenablesItems = false
        applyTitles()

        let title = NSMenuItem(title: "KeyHue", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        currentInputItem.isEnabled = false
        menu.addItem(currentInputItem)
        menu.addItem(.separator())

        // 앱·창을 바꿀 때: 그대로 두기 / 기본 입력 소스로 전환 / 마지막 입력 소스로 복원 중 하나(ADR 0029)
        appSwitchItem.submenu = makeChoiceMenu(
            SwitchBehavior.allCases.map { ("", $0.rawValue as Any) },
            action: #selector(selectAppSwitch(_:))
        )
        windowSwitchItem.submenu = makeChoiceMenu(
            SwitchBehavior.allCases.map { ("", $0.rawValue as Any) },
            action: #selector(selectWindowSwitch(_:))
        )
        windowSwitchItem.toolTip = L("Needs Accessibility access. KeyHue only notices that the main window changed; it never reads window titles or contents.")
        // ADR 0069: only what is changed often. The HUD, leaving a text field, the
        // default input source, forgetting inputs and the log are in Settings.
        for item in [showBarItem, appSwitchItem, windowSwitchItem, windowMemoryAppItem, windowSwitchPermissionItem, windowSwitchStalledItem,
                     escapeItem, escapePermissionItem] {
            item.target = self
            menu.addItem(item)
        }
        escapePermissionItem.indentationLevel = 1
        windowMemoryAppItem.indentationLevel = 1
        windowSwitchPermissionItem.indentationLevel = 1
        windowSwitchStalledItem.indentationLevel = 1
        windowSwitchStalledItem.isEnabled = false

        let inputMethodMenu = NSMenu()
        inputMethodMenu.autoenablesItems = false
        inputMethodStatusItem.isEnabled = false
        for item in [inputMethodStatusItem, nextStepItem, routingItem, routingPermissionItem, recoveryItem, uninstallInputMethodItem] {
            item.target = self
            inputMethodMenu.addItem(item)
        }
        routingPermissionItem.indentationLevel = 1
        inputMethodMenu.addItem(.separator())
        inputMethodSettingsItem.target = self
        inputMethodMenu.addItem(inputMethodSettingsItem)
        inputMethodItem.submenu = inputMethodMenu
        menu.addItem(inputMethodItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(AppMenuCommands.showSettings), keyEquivalent: ",")
        settings.target = commands
        menu.addItem(settings)
        updateItem.target = commands
        menu.addItem(updateItem)
        refreshUpdateItem()
        let about = NSMenuItem(title: L("About KeyHue"), action: #selector(AppMenuCommands.showAbout), keyEquivalent: "")
        about.target = commands
        menu.addItem(about)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit KeyHue"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        updateCurrentInput()
    }

    /// 고정 항목의 제목. 동적 제목(전환 대상 이름 포함)은 menuNeedsUpdate에서 정한다.
    private func applyTitles() {
        showBarItem.title = L("Show State Bar")
        escapePermissionItem.title = L("Grant Input Monitoring Access…")
        windowSwitchPermissionItem.title = L("Grant Accessibility Access…")
        inputMethodItem.title = L("KeyHue Input Method")
        uninstallInputMethodItem.title = L("Uninstall Input Method")
        routingItem.title = L("Keep KeyHue Korean/English Modes")
        routingItem.toolTip = SharedText.routingDetails
        routingPermissionItem.title = L("Grant Input Monitoring Access…")
        recoveryItem.title = L("Pause Integration and Switch to ABC")
        inputMethodSettingsItem.title = L("Input Method Settings…")
        appSwitchItem.title = L("When Switching Apps")
        windowSwitchItem.title = L("When Switching Windows in the Same App")
        windowMemoryAppItem.toolTip = L("Restores the input source of each window (tab) in this app. Other apps keep one input source for the whole app.")
    }

    private func makeChoiceMenu(_ choices: [(String, Any)], action: Selector) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (title, value) in choices {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Update

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        actions?.refreshFeatureStatuses()
        let statuses = actions?.featureStatuses ?? FeatureStatuses()
        let settings = settingsStore.settings
        let sources = InputSourceController.enabledSources()
        // 무엇을 체크하고 보일지는 Core의 StatusMenuState가 정한다(테스트 대상). 여기서는 그리기만 한다.
        let state = StatusMenuState(
            settings: settings,
            enabledSources: sources,
            escape: statuses.escape,
            textFocus: statuses.textFocus,
            windowSwitch: statuses.windowSwitch,
            windowSwitchStalledApp: statuses.windowSwitchStalledApp,
            frontApp: Self.frontApp
        )
        apply(state)
        apply(InputMethodMenuState(
            installation: statuses.inputMethodInstallation,
            isBusy: statuses.isInputMethodOperationRunning,
            settings: settings,
            sources: sources,
            routingStatus: statuses.inputMethodRouting
        ))
        updateCurrentInput()
    }

    func apply(_ state: InputMethodMenuState) {
        inputMethodItem.state = Self.stateValue(state.integration)
        inputMethodStatusItem.title = state.isBusy ? L("Managing Input Method…") : state.phase.title
        nextStep = state.nextStep
        nextStepItem.isHidden = state.nextStep == nil
        nextStepItem.title = state.nextStep?.title ?? ""
        nextStepItem.isEnabled = state.isNextStepEnabled
        routingItem.isHidden = state.isRoutingHidden
        routingItem.isEnabled = state.isRoutingEnabled
        routingItem.state = Self.stateValue(state.routing)
        routingPermissionItem.isHidden = state.isRoutingPermissionHidden
        recoveryItem.isHidden = state.isRecoveryHidden
        uninstallInputMethodItem.isHidden = state.isUninstallHidden
        uninstallInputMethodItem.isEnabled = state.isUninstallEnabled
    }

    func apply(_ state: StatusMenuState) {
        let defaultName = state.defaultSourceName ?? L("Default Input Source")
        showBarItem.state = state.showStateBar ? .on : .off
        Self.applyChoices(appSwitchItem, selected: state.onAppSwitch, defaultName: defaultName)
        Self.applyChoices(windowSwitchItem, selected: state.onWindowSwitch, defaultName: defaultName)
        // 권한이 없어 동작하지 못하면 상위 항목에 "–"로 알린다
        windowSwitchItem.state = state.windowSwitch == .needsPermission ? .mixed : .off
        windowMemoryApp = state.windowMemoryApp
        windowMemoryAppItem.isHidden = state.windowMemoryApp == nil
        if let app = state.windowMemoryApp {
            windowMemoryAppItem.title = L("Remember Each Window in %@", app.name)
            windowMemoryAppItem.state = state.remembersEachWindowInFrontApp ? .on : .off
        }
        windowSwitchPermissionItem.isHidden = !state.showsWindowSwitchPermissionItem
        windowSwitchStalledItem.isHidden = state.windowSwitchStalledApp == nil
        if let app = state.windowSwitchStalledApp {
            windowSwitchStalledItem.title = "⚠︎ " + L("Can't detect window switches in %@", app)
            windowSwitchStalledItem.toolTip = SharedText.windowSwitchStalled(in: app)
        }

        escapeItem.title = L("Switch to %@ on ESC", defaultName)
        escapeItem.state = Self.menuState(state.escape)
        escapePermissionItem.isHidden = !state.showsEscapePermissionItem

    }

    /// 메뉴를 연 앱. 메뉴바 메뉴는 KeyHue를 앞으로 가져오지 않으므로 쓰고 있던 앱이다. KeyHue 자신(설정 창)은 아니다.
    private static var frontApp: FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier else { return nil }
        return FrontApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    /// 전환 동작 하위 메뉴: 제목(기본 입력 소스 이름 포함)과 체크를 갱신한다.
    private static func applyChoices(_ item: NSMenuItem, selected: SwitchBehavior, defaultName: String) {
        for child in item.submenu?.items ?? [] {
            guard let behavior = (child.representedObject as? String).flatMap(SwitchBehavior.init(rawValue:)) else { continue }
            child.title = behavior.title(defaultName: defaultName)
            child.state = behavior == selected ? .on : .off
        }
    }

    private func updateCurrentInput() {
        let snapshot = stateStore.snapshot
        var name = snapshot.state.displayName
        if snapshot.isCapsLockOn, let source = snapshot.source {
            name += " (\(source.displayName))"
        }
        currentInputItem.title = L("Current Input: %@", name)
        currentInputItem.image = Self.swatch(displaySettings().color(for: snapshot.state))
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        icon.render(on: button, settings: displaySettings(), state: stateStore.state)
    }

    // MARK: - Actions

    @objc private func performNextStep() {
        switch nextStep {
        case .install?: actions?.installInputMethod()
        case .openInputSources?: actions?.openInputSourceSettings()
        case nil: break
        }
    }

    @objc private func uninstallInputMethod() { actions?.uninstallInputMethod() }
    @objc private func showInputMethodSettings() { actions?.showInputMethodSettings() }

    @objc private func toggleRouting() {
        actions?.setInputMethodRouting(!settingsStore.settings.routeInputMethodPair)
    }

    @objc private func pauseIntegration() { actions?.pauseInputMethodIntegration() }

    // A setting that needs no permission goes to the store; one that does goes through
    // `actions`, which asks first. The settings window follows the same rule (`SettingsModel`).
    @objc private func toggleShowBar() {
        settingsStore.update { $0.showStateBar.toggle() }
    }

    @objc private func selectAppSwitch(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let behavior = SwitchBehavior(rawValue: raw) else { return }
        settingsStore.update { $0.onAppSwitch = behavior }
    }

    @objc private func toggleEscape() {
        actions?.setResetOnEscape(!settingsStore.settings.resetOnEscape)
    }

    @objc private func selectWindowSwitch(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let behavior = SwitchBehavior(rawValue: raw) else { return }
        actions?.setOnWindowSwitch(behavior)
    }

    @objc private func toggleWindowMemoryApp() {
        guard let app = windowMemoryApp else { return }
        actions?.setRemembersEachWindow(windowMemoryAppItem.state != .on, in: [app.bundleID])
    }

    @objc private func openInputMonitoring() {
        actions?.openInputMonitoringSettings()
    }

    @objc private func openAccessibility() {
        actions?.openAccessibilitySettings()
    }

    private func refreshUpdateItem() {
        updateItem.title = updates.menuTitle
        updateItem.isEnabled = !updates.state.isChecking
    }
}
