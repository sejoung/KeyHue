import AppKit
import KeyHueCore

/// 메뉴·설정 창에서 권한/시스템 연동이 필요한 동작. 단순 설정 토글은 SettingsStore를 직접 갱신한다.
@MainActor
protocol StatusBarActions: AnyObject {
    var escapeResetStatus: FeatureStatus { get }
    var textFocusResetStatus: FeatureStatus { get }
    var windowSwitchResetStatus: FeatureStatus { get }
    /// 잘못된 언어 경고(실험적, ADR 0041).
    var wrongLanguageStatus: FeatureStatus { get }
    var inputMethodRoutingStatus: FeatureStatus { get }
    var inputMethodInstallationStatus: InputMethodInstallationStatus { get }
    var isInputMethodOperationRunning: Bool { get }
    func setInputMethodEnabled(_ enabled: Bool)
    func installInputMethod()
    func uninstallInputMethod()
    func openInputSourceSettings()
    func setInputMethodRouting(_ enabled: Bool)
    func pauseInputMethodIntegration()
    /// 한글 음절 모델을 읽지 못해 경고가 동작하지 않는다(번들이 깨졌거나 번들 없이 실행).
    var isWrongLanguageModelMissing: Bool { get }
    /// 창 전환을 감지하지 못하고 있는 맨 앞 앱 이름. `windowSwitchResetStatus` 다음에 읽는다(그때 다시 붙기를 시도한다).
    var windowSwitchStalledApp: String? { get }
    var isLaunchAtLoginEnabled: Bool { get }
    /// macOS가 커서 옆에 띄우는 입력 소스 표시를 숨겼는지(macOS 설정, ADR 0034).
    var isSystemInputIndicatorHidden: Bool { get }
    func setResetOnEscape(_ enabled: Bool)
    func setResetOnTextFocusLoss(_ enabled: Bool)
    func setWarnOnWrongLanguage(_ enabled: Bool)
    func setOnWindowSwitch(_ behavior: SwitchBehavior)
    func openInputMonitoringSettings()
    func openAccessibilitySettings()
    func setLaunchAtLogin(_ enabled: Bool)
    func setSystemInputIndicatorHidden(_ hidden: Bool)
    func forgetPerAppInputs()
    func showSettings()
    func showUpdates()
    /// 로그 파일을 Finder에서 보여준다(ADR 0036).
    func showLogFile()
}

extension InputState {
    /// 메뉴·설정 창에 표시할 이름. 입력 소스 이름은 macOS가 OS 언어로 준다.
    var displayName: String {
        switch self {
        case .source(let info): return info.displayName
        case .capsLock: return L("Caps Lock")
        case .unknown: return L("Unknown")
        }
    }
}

/// 메뉴바 UI. 상태는 InputStateStore / SettingsStore에서만 읽는다.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate, NSUserInterfaceValidations {
    private let settingsStore: SettingsStore
    private let stateStore: InputStateStore
    private let updates: UpdateChecker
    private weak var actions: StatusBarActions?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let updateItem = NSMenuItem(title: "", action: #selector(updateAction), keyEquivalent: "")
    private let currentInputItem = NSMenuItem()
    private let showBarItem = NSMenuItem(title: "", action: #selector(toggleShowBar), keyEquivalent: "")
    private let appSwitchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let escapeItem = NSMenuItem(title: "", action: #selector(toggleEscape), keyEquivalent: "")
    private let escapePermissionItem = NSMenuItem(title: "", action: #selector(openInputMonitoring), keyEquivalent: "")
    private let windowSwitchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let windowSwitchPermissionItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private let windowSwitchStalledItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let installInputMethodItem = NSMenuItem(title: "", action: #selector(installInputMethod), keyEquivalent: "")
    private let uninstallInputMethodItem = NSMenuItem(title: "", action: #selector(uninstallInputMethod), keyEquivalent: "")
    private let integrationItem = NSMenuItem(title: "", action: #selector(toggleIntegration), keyEquivalent: "")
    private let routingItem = NSMenuItem(title: "", action: #selector(toggleRouting), keyEquivalent: "")
    private let recoveryItem = NSMenuItem(title: "", action: #selector(pauseIntegration), keyEquivalent: "")
    private let integrationNoticeItem = NSMenuItem(title: "", action: #selector(openInputSources), keyEquivalent: "")
    private let routingPermissionItem = NSMenuItem(title: "", action: #selector(openInputMonitoring), keyEquivalent: "")
    private let defaultSourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hudItem = NSMenuItem(title: "", action: #selector(toggleHUD), keyEquivalent: "")
    private let forgetItem = NSMenuItem(title: "", action: #selector(forgetInputs), keyEquivalent: "")
    private let textFocusItem = NSMenuItem(title: "", action: #selector(toggleTextFocus), keyEquivalent: "")
    private let textFocusPermissionItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")

    /// docs/icon.png에서 추출한 카멜레온 실루엣(alpha mask). 번들 없이 실행하면 nil.
    private let chameleon = ChameleonImage.menuBarMask
    private var renderedIconKey: String?

    init(settingsStore: SettingsStore, stateStore: InputStateStore, actions: StatusBarActions, updates: UpdateChecker = UpdateChecker()) {
        self.settingsStore = settingsStore
        self.stateStore = stateStore
        self.updates = updates
        self.actions = actions
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
        for item in [showBarItem, appSwitchItem, windowSwitchItem, windowSwitchPermissionItem, windowSwitchStalledItem, forgetItem, escapeItem, escapePermissionItem] {
            item.target = self
            menu.addItem(item)
        }
        escapePermissionItem.indentationLevel = 1
        windowSwitchPermissionItem.indentationLevel = 1
        windowSwitchStalledItem.indentationLevel = 1
        windowSwitchStalledItem.isEnabled = false
        forgetItem.indentationLevel = 1
        menu.addItem(defaultSourceItem)
        for item in [installInputMethodItem, integrationItem, routingItem, routingPermissionItem, integrationNoticeItem, recoveryItem, uninstallInputMethodItem] {
            item.target = self
            menu.addItem(item)
        }
        integrationNoticeItem.indentationLevel = 1
        routingPermissionItem.indentationLevel = 1
        menu.addItem(.separator())

        for item in [hudItem, textFocusItem, textFocusPermissionItem] {
            item.target = self
            menu.addItem(item)
        }
        textFocusPermissionItem.indentationLevel = 1
        textFocusItem.toolTip = L("Experimental. Requires Accessibility access. KeyHue only reads the focused element's role, never its contents.")
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        updateItem.target = self
        menu.addItem(updateItem)
        refreshUpdateItem()
        let logs = NSMenuItem(title: L("Show Log File"), action: #selector(revealLogFile), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        let about = NSMenuItem(title: L("About KeyHue"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
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
        defaultSourceItem.title = L("Default Input Source")
        integrationItem.title = L("Use KeyHue Input Method (Experimental)")
        installInputMethodItem.title = L("Install and Use Input Method…")
        uninstallInputMethodItem.title = L("Uninstall Input Method")
        routingItem.title = L("Keep KeyHue Korean/English Modes (Experimental)")
        routingItem.toolTip = L("ABC selected from a KeyHue mode is redirected to the other KeyHue mode, including manual ABC selection. Other languages are kept. Use Pause Integration and Switch to ABC to leave the pair. Very fast typing may arrive before macOS reports the switch.")
        integrationNoticeItem.title = L("Enable both KeyHue input modes in System Settings first.")
        routingPermissionItem.title = L("Grant Input Monitoring Access…")
        recoveryItem.title = L("Pause Integration and Switch to ABC")
        hudItem.title = L("Show HUD on Change")
        appSwitchItem.title = L("When Switching Apps")
        windowSwitchItem.title = L("When Switching Windows in the Same App")
        forgetItem.title = L("Forget Remembered Inputs")
        textFocusPermissionItem.title = L("Grant Accessibility Access…")
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

    static func title(for behavior: SwitchBehavior, defaultName: String) -> String {
        switch behavior {
        case .keep: return L("Keep As Is")
        case .switchToDefault: return L("Switch to %@", defaultName)
        case .restoreLast: return L("Restore Last Input Source")
        }
    }

    static func title(for position: BarPosition) -> String {
        switch position {
        case .top: return L("Top")
        case .bottom: return L("Bottom")
        case .left: return L("Left")
        case .right: return L("Right")
        }
    }

    /// 자동 전환 목표: Automatic(현재 자동 선택 결과 표시) + 켜져 있는 입력 소스. 내용은 Core의 `DefaultSourceMenu`가 정한다.
    private func makeDefaultSourceMenu(_ model: DefaultSourceMenu) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let autoTitle = L("Automatic (%@)", model.automaticName ?? L("No Available Input Source"))
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(selectDefaultSource(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = ""
        autoItem.state = model.isAutomaticChecked ? .on : .off
        submenu.addItem(autoItem)
        if model.showsUnavailableChoice {
            let missing = NSMenuItem(title: L("Unavailable Input Source"), action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.state = .on
            submenu.addItem(missing)
        }
        submenu.addItem(.separator())
        for choice in model.choices {
            let item = NSMenuItem(title: choice.title, action: #selector(selectDefaultSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.isChecked ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Update

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let settings = settingsStore.settings
        let sources = InputSourceController.enabledSources()
        // 무엇을 체크하고 보일지는 Core의 StatusMenuState가 정한다(테스트 대상). 여기서는 그리기만 한다.
        let state = StatusMenuState(
            settings: settings,
            enabledSources: sources,
            escape: actions?.escapeResetStatus ?? .off,
            textFocus: actions?.textFocusResetStatus ?? .off,
            windowSwitch: actions?.windowSwitchResetStatus ?? .off,
            windowSwitchStalledApp: actions?.windowSwitchStalledApp
        )
        apply(state)
        apply(InputMethodMenuState(
            installation: actions?.inputMethodInstallationStatus ?? .init(),
            isBusy: actions?.isInputMethodOperationRunning ?? false,
            settings: settings,
            sources: sources,
            routingStatus: actions?.inputMethodRoutingStatus ?? .off
        ))
        defaultSourceItem.submenu = makeDefaultSourceMenu(DefaultSourceMenu(settings: settings, sources: sources))
        updateCurrentInput()
    }

    func apply(_ state: InputMethodMenuState) {
        installInputMethodItem.title = Self.title(for: state.installAction)
        installInputMethodItem.isEnabled = state.isInstallEnabled
        uninstallInputMethodItem.isHidden = state.isUninstallHidden
        uninstallInputMethodItem.isEnabled = state.isUninstallEnabled
        integrationItem.isEnabled = state.isIntegrationEnabled
        integrationItem.state = Self.stateValue(state.integration)
        routingItem.isEnabled = state.isRoutingEnabled
        routingItem.state = Self.stateValue(state.routing)
        routingPermissionItem.isHidden = state.isRoutingPermissionHidden
        integrationNoticeItem.isHidden = state.isNoticeHidden
        integrationNoticeItem.isEnabled = state.isNoticeEnabled
        recoveryItem.isHidden = state.isRecoveryHidden
    }

    static func title(for action: InputMethodMenuState.InstallAction) -> String {
        switch action {
        case .install: return L("Install and Use Input Method…")
        case .enable: return L("Enable Input Method…")
        case .update: return L("Update and Use Input Method…")
        }
    }

    func apply(_ state: StatusMenuState) {
        let defaultName = state.defaultSourceName ?? L("Default Input Source")
        showBarItem.state = state.showStateBar ? .on : .off
        Self.applyChoices(appSwitchItem, selected: state.onAppSwitch, defaultName: defaultName)
        Self.applyChoices(windowSwitchItem, selected: state.onWindowSwitch, defaultName: defaultName)
        // 권한이 없어 동작하지 못하면 상위 항목에 "–"로 알린다
        windowSwitchItem.state = state.windowSwitch == .needsPermission ? .mixed : .off
        windowSwitchPermissionItem.isHidden = !state.showsWindowSwitchPermissionItem
        windowSwitchStalledItem.isHidden = state.windowSwitchStalledApp == nil
        if let app = state.windowSwitchStalledApp {
            windowSwitchStalledItem.title = "⚠︎ " + L("Can't detect window switches in %@", app)
            windowSwitchStalledItem.toolTip = L("%@ isn't answering Accessibility requests, so KeyHue can't see its window switches. Switching to another app and back tries again.", app)
        }
        forgetItem.isHidden = !state.showsForgetItem

        escapeItem.title = L("Switch to %@ on ESC", defaultName)
        escapeItem.state = Self.menuState(state.escape)
        escapePermissionItem.isHidden = !state.showsEscapePermissionItem

        hudItem.state = state.showHUD ? .on : .off

        textFocusItem.title = L("Switch to %@ When Leaving Text Field", defaultName)
        textFocusItem.state = Self.menuState(state.textFocus)
        textFocusPermissionItem.isHidden = !state.showsTextFocusPermissionItem
    }

    /// 전환 동작 하위 메뉴: 제목(기본 입력 소스 이름 포함)과 체크를 갱신한다.
    private static func applyChoices(_ item: NSMenuItem, selected: SwitchBehavior, defaultName: String) {
        for child in item.submenu?.items ?? [] {
            guard let behavior = (child.representedObject as? String).flatMap(SwitchBehavior.init(rawValue:)) else { continue }
            child.title = title(for: behavior, defaultName: defaultName)
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
        currentInputItem.image = Self.swatch(settingsStore.settings.color(for: snapshot.state))
    }

    /// 카멜레온을 현재 상태색으로 칠한다(카멜레온처럼 색이 바뀐다). 설정이 꺼져 있으면 template.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let settings = settingsStore.settings
        let color = settings.color(for: stateStore.state)
        let key = settings.tintMenuBarIcon ? color.hexString : "template"
        guard key != renderedIconKey else { return }
        renderedIconKey = key

        guard let chameleon else {
            let fallback = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyHue")
            fallback?.isTemplate = true
            button.image = fallback
            return
        }
        if settings.tintMenuBarIcon {
            let tinted = ChameleonImage.tinted(chameleon, color: color)
            tinted.accessibilityDescription = "KeyHue"
            button.image = tinted
        } else {
            let template = chameleon.copy() as! NSImage
            template.isTemplate = true
            template.accessibilityDescription = "KeyHue"
            button.image = template
        }
    }

    private static func menuState(_ status: FeatureStatus) -> NSControl.StateValue {
        stateValue(MenuCheck(status))
    }

    static func stateValue(_ check: MenuCheck) -> NSControl.StateValue {
        switch check {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
    }

    static func swatch(_ color: RGBAColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Actions

    @objc private func toggleIntegration() {
        actions?.setInputMethodEnabled(!settingsStore.settings.integrateInputMethod)
    }

    @objc private func installInputMethod() { actions?.installInputMethod() }
    @objc private func uninstallInputMethod() { actions?.uninstallInputMethod() }
    @objc private func openInputSources() { actions?.openInputSourceSettings() }

    @objc private func toggleRouting() {
        actions?.setInputMethodRouting(!settingsStore.settings.routeInputMethodPair)
    }

    @objc private func pauseIntegration() { actions?.pauseInputMethodIntegration() }

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

    @objc private func openInputMonitoring() {
        actions?.openInputMonitoringSettings()
    }

    @objc private func selectDefaultSource(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        settingsStore.update { $0.defaultSourceID = (id?.isEmpty ?? true) ? nil : id }
    }










    @objc private func toggleHUD() {
        settingsStore.update { $0.showHUD.toggle() }
    }

    @objc private func forgetInputs() {
        actions?.forgetPerAppInputs()
    }

    @objc private func toggleTextFocus() {
        actions?.setResetOnTextFocusLoss(!settingsStore.settings.resetOnTextFocusLoss)
    }

    @objc private func openAccessibility() {
        actions?.openAccessibilitySettings()
    }



    @objc func showSettings() {
        actions?.showSettings()
    }

    private func refreshUpdateItem() {
        updateItem.title = updates.menuTitle
        updateItem.isEnabled = !updates.state.isChecking
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action != #selector(updateAction) || !updates.state.isChecking
    }

    @objc func updateAction() {
        if let url = updates.releaseURL {
            NSWorkspace.shared.open(url)
        } else {
            actions?.showUpdates()
            Task { await updates.checkNow() }
        }
    }

    @objc private func revealLogFile() {
        actions?.showLogFile()
    }

    /// 문제를 알릴 때 첨부할 로그 파일을 Finder에서 보여준다(ADR 0036). 아직 없으면 폴더를 연다.
    static func showLogFile() {
        Log.file?.flush()
        let file = Log.fileURL
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    static let repositoryURL = URL(string: "https://github.com/sejoung/KeyHue")!

    @objc func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: L("KeyHue never records what you type.") + "\n",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        )
        credits.append(NSAttributedString(
            string: "github.com/sejoung/KeyHue",
            attributes: [.font: font, .link: Self.repositoryURL, .paragraphStyle: paragraph]
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// 색을 지정할 수 있는 대상: 입력 소스 하나 또는 Caps Lock.
enum ColorTarget: Hashable {
    case source(InputSourceInfo)
    case capsLock

    var title: String {
        switch self {
        case .source(let info): return info.displayName
        case .capsLock: return L("Caps Lock")
        }
    }

    func color(in settings: KeyHueSettings) -> RGBAColor {
        switch self {
        case .source(let info): return settings.color(for: info)
        case .capsLock: return settings.capsLockColor
        }
    }

    func setColor(_ color: RGBAColor, in settings: inout KeyHueSettings) {
        switch self {
        case .source(let info): settings.setColor(color, for: info)
        case .capsLock: settings.capsLockColor = color
        }
    }
}
