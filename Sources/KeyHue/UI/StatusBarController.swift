import AppKit
import KeyHueCore

/// 권한이 필요한 옵션의 현재 상태.
enum FeatureStatus {
    case off
    case active
    case needsPermission
}

/// 메뉴에서 권한/시스템 연동이 필요한 동작. 단순 설정 토글은 SettingsStore를 직접 갱신한다.
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
    private let showBarItem = NSMenuItem(title: "Show State Bar", action: #selector(toggleShowBar), keyEquivalent: "")
    private let appSwitchItem = NSMenuItem(title: "Reset to ABC on App Switch", action: #selector(toggleAppSwitch), keyEquivalent: "")
    private let escapeItem = NSMenuItem(title: "Reset to ABC on ESC", action: #selector(toggleEscape), keyEquivalent: "")
    private let escapePermissionItem = NSMenuItem(title: "Grant Input Monitoring Access…", action: #selector(openInputMonitoring), keyEquivalent: "")
    private let thicknessItem = NSMenuItem(title: "Bar Thickness", action: nil, keyEquivalent: "")
    private let colorsItem = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
    private let displaysItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
    private let hudItem = NSMenuItem(title: "Show HUD on Change", action: #selector(toggleHUD), keyEquivalent: "")
    private let rememberItem = NSMenuItem(title: "Remember Input per App", action: #selector(toggleRemember), keyEquivalent: "")
    private let forgetItem = NSMenuItem(title: "Forget Remembered Inputs", action: #selector(forgetInputs), keyEquivalent: "")
    private let textFocusItem = NSMenuItem(title: "Reset to ABC When Leaving Text Field", action: #selector(toggleTextFocus), keyEquivalent: "")
    private let textFocusPermissionItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
    private let tintIconItem = NSMenuItem(title: "Tint Menu Bar Icon", action: #selector(toggleTintIcon), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    /// Custom… 색상 편집 중인 상태.
    private var editingColorState: InputState?

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

    private func buildMenu() {
        statusItem.button?.toolTip = "KeyHue"
        updateStatusIcon()

        menu.delegate = self
        menu.autoenablesItems = false

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
        menu.addItem(.separator())

        thicknessItem.submenu = makeThicknessMenu()
        colorsItem.submenu = makeColorsMenu()
        displaysItem.submenu = makeDisplaysMenu()
        [thicknessItem, colorsItem, displaysItem].forEach(menu.addItem)
        menu.addItem(.separator())

        for item in [hudItem, rememberItem, forgetItem, textFocusItem, textFocusPermissionItem] {
            item.target = self
            menu.addItem(item)
        }
        forgetItem.indentationLevel = 1
        textFocusPermissionItem.indentationLevel = 1
        textFocusItem.toolTip = "Experimental. Requires Accessibility access. KeyHue only reads the focused element's role, never its contents."
        menu.addItem(.separator())

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        let about = NSMenuItem(title: "About KeyHue", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit KeyHue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        updateCurrentInput()
    }

    private func makeThicknessMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for height in KeyHueSettings.barHeightChoices {
            let item = NSMenuItem(title: "\(Int(height))px", action: #selector(selectThickness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = height
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeColorsMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for state in InputState.allCases {
            let item = NSMenuItem(title: state.displayName, action: nil, keyEquivalent: "")
            item.representedObject = state.rawValue
            let presets = NSMenu()
            presets.autoenablesItems = false
            for preset in RGBAColor.presets {
                let presetItem = NSMenuItem(title: preset.name, action: #selector(selectPresetColor(_:)), keyEquivalent: "")
                presetItem.target = self
                presetItem.representedObject = ColorChoice(state: state, color: preset.color)
                presetItem.image = Self.swatch(preset.color)
                presets.addItem(presetItem)
            }
            presets.addItem(.separator())
            let custom = NSMenuItem(title: "Custom…", action: #selector(selectCustomColor(_:)), keyEquivalent: "")
            custom.target = self
            custom.representedObject = state.rawValue
            presets.addItem(custom)
            item.submenu = presets
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        tintIconItem.target = self
        submenu.addItem(tintIconItem)
        let reset = NSMenuItem(title: "Reset to Defaults", action: #selector(resetColors), keyEquivalent: "")
        reset.target = self
        submenu.addItem(reset)
        return submenu
    }

    private func makeDisplaysMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let titles: [DisplayPolicy: String] = [
            .allScreens: "All Displays",
            .activeScreen: "Active Display Only"
        ]
        for policy in DisplayPolicy.allCases {
            let item = NSMenuItem(title: titles[policy] ?? policy.rawValue, action: #selector(selectDisplayPolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy.rawValue
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Update

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let settings = settingsStore.settings

        updateCurrentInput()
        showBarItem.state = settings.showStateBar ? .on : .off
        appSwitchItem.state = settings.resetOnAppSwitch ? .on : .off

        let escapeStatus = actions?.escapeResetStatus ?? .off
        escapeItem.state = Self.menuState(escapeStatus)
        escapePermissionItem.isHidden = escapeStatus != .needsPermission

        for item in thicknessItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? Double) == settings.barHeight ? .on : .off
        }
        for item in colorsItem.submenu?.items ?? [] {
            guard let raw = item.representedObject as? String, let state = InputState(rawValue: raw) else { continue }
            let color = settings.color(for: state)
            item.image = Self.swatch(color)
            for preset in item.submenu?.items ?? [] {
                preset.state = (preset.representedObject as? ColorChoice)?.color == color ? .on : .off
            }
        }
        for item in displaysItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String) == settings.displayPolicy.rawValue ? .on : .off
        }
        tintIconItem.state = settings.tintMenuBarIcon ? .on : .off
        displaysItem.isEnabled = settings.showStateBar || settings.showHUD
        thicknessItem.isEnabled = settings.showStateBar

        hudItem.state = settings.showHUD ? .on : .off
        rememberItem.state = settings.rememberInputPerApp ? .on : .off
        forgetItem.isHidden = !settings.rememberInputPerApp

        let textFocusStatus = actions?.textFocusResetStatus ?? .off
        textFocusItem.state = Self.menuState(textFocusStatus)
        textFocusPermissionItem.isHidden = textFocusStatus != .needsPermission

        launchAtLoginItem.state = (actions?.isLaunchAtLoginEnabled ?? false) ? .on : .off
    }

    private func updateCurrentInput() {
        let snapshot = stateStore.snapshot
        var title = "Current Input: \(snapshot.state.displayName)"
        if let name = snapshot.source?.localizedName, !name.isEmpty, name != snapshot.state.displayName {
            title += " (\(name))"
        }
        currentInputItem.title = title
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
            tinted.accessibilityDescription = "KeyHue: \(stateStore.state.displayName)"
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

    private static func swatch(_ color: RGBAColor) -> NSImage {
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

    @objc private func selectThickness(_ sender: NSMenuItem) {
        guard let height = sender.representedObject as? Double else { return }
        settingsStore.update { $0.barHeight = height }
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        settingsStore.update { $0.setColor(choice.color, for: choice.state) }
    }

    @objc private func selectCustomColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let state = InputState(rawValue: raw) else { return }
        editingColorState = state
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(settingsStore.settings.color(for: state))
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.title = "\(state.displayName) Color"
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        guard let state = editingColorState, let color = sender.color.rgbaColor else { return }
        settingsStore.update { $0.setColor(color, for: state) }
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

    @objc private func toggleLaunchAtLogin() {
        actions?.setLaunchAtLogin(!(actions?.isLaunchAtLoginEnabled ?? false))
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "KeyHue never records what you type.")
        ])
    }
}

/// Colors 서브메뉴 항목의 representedObject.
private final class ColorChoice: NSObject {
    let state: InputState
    let color: RGBAColor

    init(state: InputState, color: RGBAColor) {
        self.state = state
        self.color = color
    }
}
