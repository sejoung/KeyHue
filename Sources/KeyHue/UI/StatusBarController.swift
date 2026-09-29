import AppKit
import KeyHueCore

/// 권한이 필요한 옵션의 현재 상태.
enum FeatureStatus {
    case off
    case active
    case needsPermission
}

/// 메뉴·설정 창에서 권한/시스템 연동이 필요한 동작. 단순 설정 토글은 SettingsStore를 직접 갱신한다.
@MainActor
protocol StatusBarActions: AnyObject {
    var escapeResetStatus: FeatureStatus { get }
    var textFocusResetStatus: FeatureStatus { get }
    var isLaunchAtLoginEnabled: Bool { get }
    func setResetOnEscape(_ enabled: Bool)
    func setResetOnTextFocusLoss(_ enabled: Bool)
    func openInputMonitoringSettings()
    func openAccessibilitySettings()
    func setLaunchAtLogin(_ enabled: Bool)
    func forgetPerAppInputs()
    func showSettings()
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

extension InputSourceInfo {
    var displayName: String { localizedName.isEmpty ? id : localizedName }
}

/// 메뉴바 UI. 상태는 InputStateStore / SettingsStore에서만 읽는다.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let settingsStore: SettingsStore
    private let stateStore: InputStateStore
    private weak var actions: StatusBarActions?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let currentInputItem = NSMenuItem()
    private let showBarItem = NSMenuItem(title: "", action: #selector(toggleShowBar), keyEquivalent: "")
    private let appSwitchItem = NSMenuItem(title: "", action: #selector(toggleAppSwitch), keyEquivalent: "")
    private let escapeItem = NSMenuItem(title: "", action: #selector(toggleEscape), keyEquivalent: "")
    private let escapePermissionItem = NSMenuItem(title: "", action: #selector(openInputMonitoring), keyEquivalent: "")
    private let defaultSourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let positionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let thicknessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let opacityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let colorsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let displaysItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hudItem = NSMenuItem(title: "", action: #selector(toggleHUD), keyEquivalent: "")
    private let rememberItem = NSMenuItem(title: "", action: #selector(toggleRemember), keyEquivalent: "")
    private let forgetItem = NSMenuItem(title: "", action: #selector(forgetInputs), keyEquivalent: "")
    private let textFocusItem = NSMenuItem(title: "", action: #selector(toggleTextFocus), keyEquivalent: "")
    private let textFocusPermissionItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private let tintIconItem = NSMenuItem(title: "", action: #selector(toggleTintIcon), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let dockIconItem = NSMenuItem(title: "", action: #selector(toggleDockIcon), keyEquivalent: "")

    /// Custom… 색상 편집 대상.
    private var editingColorTarget: ColorTarget?

    /// docs/icon.png에서 추출한 카멜레온 실루엣(alpha mask). 번들 없이 실행하면 nil.
    private let chameleon = Bundle.main.image(forResource: "MenuBarIcon")
    private var renderedIconKey: String?

    init(settingsStore: SettingsStore, stateStore: InputStateStore, actions: StatusBarActions) {
        self.settingsStore = settingsStore
        self.stateStore = stateStore
        self.actions = actions
        super.init()
        buildMenu()

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

        for item in [showBarItem, appSwitchItem, escapeItem, escapePermissionItem] {
            item.target = self
            menu.addItem(item)
        }
        escapePermissionItem.indentationLevel = 1
        menu.addItem(defaultSourceItem)
        menu.addItem(.separator())

        positionItem.submenu = makeChoiceMenu(
            BarPosition.allCases.map { (Self.title(for: $0), $0.rawValue as Any) },
            action: #selector(selectPosition(_:))
        )
        thicknessItem.submenu = makeChoiceMenu(
            KeyHueSettings.barHeightChoices.map { ("\(Int($0))px", $0 as Any) },
            action: #selector(selectThickness(_:))
        )
        opacityItem.submenu = makeChoiceMenu(
            KeyHueSettings.barOpacityChoices.map { ("\(Int(($0 * 100).rounded()))%", $0 as Any) },
            action: #selector(selectOpacity(_:))
        )
        displaysItem.submenu = makeChoiceMenu(
            [(L("All Displays"), DisplayPolicy.allScreens.rawValue as Any), (L("Active Display Only"), DisplayPolicy.activeScreen.rawValue as Any)],
            action: #selector(selectDisplayPolicy(_:))
        )
        [positionItem, thicknessItem, opacityItem, colorsItem, displaysItem].forEach(menu.addItem)
        menu.addItem(.separator())

        for item in [hudItem, rememberItem, forgetItem, textFocusItem, textFocusPermissionItem] {
            item.target = self
            menu.addItem(item)
        }
        forgetItem.indentationLevel = 1
        textFocusPermissionItem.indentationLevel = 1
        textFocusItem.toolTip = L("Experimental. Requires Accessibility access. KeyHue only reads the focused element's role, never its contents.")
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        dockIconItem.target = self
        menu.addItem(dockIconItem)
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
        defaultSourceItem.title = L("Default Input Source")
        positionItem.title = L("Bar Position")
        thicknessItem.title = L("Bar Thickness")
        opacityItem.title = L("Bar Opacity")
        colorsItem.title = L("Colors")
        displaysItem.title = L("Displays")
        hudItem.title = L("Show HUD on Change")
        rememberItem.title = L("Remember Input per App")
        forgetItem.title = L("Forget Remembered Inputs")
        textFocusPermissionItem.title = L("Grant Accessibility Access…")
        tintIconItem.title = L("Tint Menu Bar Icon")
        launchAtLoginItem.title = L("Launch at Login")
        dockIconItem.title = L("Show in Dock")
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

    static func title(for position: BarPosition) -> String {
        switch position {
        case .top: return L("Top")
        case .bottom: return L("Bottom")
        case .left: return L("Left")
        case .right: return L("Right")
        }
    }

    /// 켜져 있는 입력 소스마다 색 서브메뉴(프리셋 + Custom…). 입력 소스 목록이 바뀔 수 있어 열 때마다 만든다.
    private func makeColorsMenu(sources: [InputSourceInfo], settings: KeyHueSettings) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let targets = sources.map(ColorTarget.source) + [ColorTarget.capsLock]
        for target in targets {
            let current = target.color(in: settings)
            let item = NSMenuItem(title: target.title, action: nil, keyEquivalent: "")
            item.image = Self.swatch(current)
            let presets = NSMenu()
            presets.autoenablesItems = false
            for preset in RGBAColor.presets {
                let presetItem = NSMenuItem(title: L(preset.name), action: #selector(selectPresetColor(_:)), keyEquivalent: "")
                presetItem.target = self
                presetItem.representedObject = ColorChoice(target: target, color: preset.color)
                presetItem.image = Self.swatch(preset.color)
                presetItem.state = preset.color == current ? .on : .off
                presets.addItem(presetItem)
            }
            presets.addItem(.separator())
            let custom = NSMenuItem(title: L("Custom…"), action: #selector(selectCustomColor(_:)), keyEquivalent: "")
            custom.target = self
            custom.representedObject = ColorChoice(target: target, color: current)
            presets.addItem(custom)
            item.submenu = presets
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        tintIconItem.target = self
        tintIconItem.state = settings.tintMenuBarIcon ? .on : .off
        submenu.addItem(tintIconItem)
        let reset = NSMenuItem(title: L("Reset to Defaults"), action: #selector(resetColors), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)
        return submenu
    }

    /// 자동 전환 목표: Automatic(현재 자동 선택 결과 표시) + 켜져 있는 입력 소스.
    private func makeDefaultSourceMenu(sources: [InputSourceInfo], settings: KeyHueSettings) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let automatic = DefaultInputSourcePicker.pick(from: sources)
        let autoTitle = automatic.map { L("Automatic (%@)", $0.displayName) } ?? L("Automatic")
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(selectDefaultSource(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = ""
        autoItem.state = settings.defaultSourceID == nil ? .on : .off
        submenu.addItem(autoItem)
        submenu.addItem(.separator())
        for source in sources {
            let item = NSMenuItem(title: source.displayName, action: #selector(selectDefaultSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.id
            item.state = settings.defaultSourceID == source.id ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Update

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let settings = settingsStore.settings
        let sources = InputSourceController.enabledSources()
        let defaultName = DefaultInputSourcePicker.pick(from: sources, preferredID: settings.defaultSourceID)?.displayName ?? "ABC"

        updateCurrentInput()
        showBarItem.state = settings.showStateBar ? .on : .off
        appSwitchItem.title = L("Switch to %@ on App Switch", defaultName)
        appSwitchItem.state = settings.resetOnAppSwitch ? .on : .off

        let escapeStatus = actions?.escapeResetStatus ?? .off
        escapeItem.title = L("Switch to %@ on ESC", defaultName)
        escapeItem.state = Self.menuState(escapeStatus)
        escapePermissionItem.isHidden = escapeStatus != .needsPermission
        defaultSourceItem.submenu = makeDefaultSourceMenu(sources: sources, settings: settings)

        Self.check(positionItem) { ($0 as? String) == settings.barPosition.rawValue }
        Self.check(thicknessItem) { ($0 as? Double) == settings.barHeight }
        Self.check(opacityItem) { ($0 as? Double).map { abs($0 - settings.barOpacity) < 0.001 } ?? false }
        Self.check(displaysItem) { ($0 as? String) == settings.displayPolicy.rawValue }
        colorsItem.submenu = makeColorsMenu(sources: sources, settings: settings)
        displaysItem.isEnabled = settings.showStateBar || settings.showHUD
        [positionItem, thicknessItem, opacityItem].forEach { $0.isEnabled = settings.showStateBar }

        hudItem.state = settings.showHUD ? .on : .off
        rememberItem.state = settings.rememberInputPerApp ? .on : .off
        forgetItem.isHidden = !settings.rememberInputPerApp

        let textFocusStatus = actions?.textFocusResetStatus ?? .off
        textFocusItem.title = L("Switch to %@ When Leaving Text Field", defaultName)
        textFocusItem.state = Self.menuState(textFocusStatus)
        textFocusPermissionItem.isHidden = textFocusStatus != .needsPermission

        launchAtLoginItem.state = (actions?.isLaunchAtLoginEnabled ?? false) ? .on : .off
        dockIconItem.state = settings.showDockIcon ? .on : .off
    }

    private static func check(_ item: NSMenuItem, isSelected: (Any?) -> Bool) {
        for child in item.submenu?.items ?? [] {
            child.state = isSelected(child.representedObject) ? .on : .off
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
            let tinted = NSImage(size: chameleon.size, flipped: false) { rect in
                chameleon.draw(in: rect)
                NSColor(color).setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.isTemplate = false
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
        switch status {
        case .off: return .off
        case .active: return .on
        case .needsPermission: return .mixed
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

    @objc private func toggleShowBar() {
        settingsStore.update { $0.showStateBar.toggle() }
    }

    @objc private func toggleAppSwitch() {
        settingsStore.update { $0.resetOnAppSwitch.toggle() }
    }

    @objc private func toggleEscape() {
        actions?.setResetOnEscape(!settingsStore.settings.resetOnEscape)
    }

    @objc private func openInputMonitoring() {
        actions?.openInputMonitoringSettings()
    }

    @objc private func selectDefaultSource(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        settingsStore.update { $0.defaultSourceID = (id?.isEmpty ?? true) ? nil : id }
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = BarPosition(rawValue: raw) else { return }
        settingsStore.update { $0.barPosition = position }
    }

    @objc private func selectThickness(_ sender: NSMenuItem) {
        guard let height = sender.representedObject as? Double else { return }
        settingsStore.update { $0.barHeight = height }
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let opacity = sender.representedObject as? Double else { return }
        settingsStore.update { $0.barOpacity = opacity }
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        settingsStore.update { choice.target.setColor(choice.color, in: &$0) }
    }

    @objc private func selectCustomColor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        editingColorTarget = choice.target
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(choice.color)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.title = L("%@ Color", choice.target.title)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let target = editingColorTarget, let color = sender.color.rgbaColor else { return }
        settingsStore.update { target.setColor(color, in: &$0) }
    }

    @objc private func toggleTintIcon() {
        settingsStore.update { $0.tintMenuBarIcon.toggle() }
    }

    @objc private func resetColors() {
        settingsStore.update { $0.resetColors() }
    }

    @objc private func selectDisplayPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = DisplayPolicy(rawValue: raw) else { return }
        settingsStore.update { $0.displayPolicy = policy }
    }

    @objc private func toggleHUD() {
        settingsStore.update { $0.showHUD.toggle() }
    }

    @objc private func toggleRemember() {
        settingsStore.update { $0.rememberInputPerApp.toggle() }
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

    @objc private func toggleDockIcon() {
        settingsStore.update { $0.showDockIcon.toggle() }
    }

    @objc private func toggleLaunchAtLogin() {
        actions?.setLaunchAtLogin(!(actions?.isLaunchAtLoginEnabled ?? false))
    }

    @objc func showSettings() {
        actions?.showSettings()
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

/// Colors 서브메뉴 항목의 representedObject.
private final class ColorChoice: NSObject {
    let target: ColorTarget
    let color: RGBAColor

    init(target: ColorTarget, color: RGBAColor) {
        self.target = target
        self.color = color
    }
}
