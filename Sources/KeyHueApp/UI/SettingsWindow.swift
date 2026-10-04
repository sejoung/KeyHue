import AppKit
import Carbon
import KeyHueCore
import SwiftUI

/// 설정 창의 상태. SettingsStore를 SwiftUI에 연결한다(ADR 0015).
@MainActor
final class SettingsModel: NSObject, ObservableObject {
    let updates: UpdateChecker
    @Published var selectedTab: SettingsTab = .general
    @Published private(set) var settings: KeyHueSettings
    @Published private(set) var sources: [InputSourceInfo] = []
    @Published private(set) var escapeStatus: FeatureStatus = .off
    @Published private(set) var textFocusStatus: FeatureStatus = .off
    @Published private(set) var windowSwitchStatus: FeatureStatus = .off
    @Published private(set) var windowSwitchStalledApp: String?
    @Published private(set) var inputMethodInstallationStatus = InputMethodInstallationStatus()
    @Published private(set) var inputMethodOperationRunning = false
    @Published private(set) var inputMethodRoutingStatus: FeatureStatus = .off
    @Published private(set) var wrongLanguageStatus: FeatureStatus = .off
    @Published private(set) var wrongLanguageModelMissing = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var systemIndicatorHidden = false

    private let store: SettingsStore
    private weak var actions: StatusBarActions?
    /// Correction failures and undone corrections (ADR 0065).
    let feedback: CorrectionFeedbackStore
    /// 켜진 입력 소스 목록. 스크린샷 렌더링에서는 예시 목록으로 바꾼다.
    private let sourcesProvider: @MainActor () -> [InputSourceInfo]

    init(
        store: SettingsStore,
        actions: StatusBarActions,
        updates: UpdateChecker = UpdateChecker(),
        feedback: CorrectionFeedbackStore = .shared,
        sourcesProvider: @escaping @MainActor () -> [InputSourceInfo] = InputSourceController.enabledSources
    ) {
        self.store = store
        self.feedback = feedback
        self.updates = updates
        self.actions = actions
        self.sourcesProvider = sourcesProvider
        self.settings = store.settings
        super.init()
        store.addObserver { [weak self] _, new in
            self?.settings = new
            self?.refreshStatuses()
        }
        // 시스템 설정에서 입력 소스를 추가/삭제하면 목록을 갱신한다(즉시 전달, ADR 0023).
        if let name = kTISNotifyEnabledKeyboardInputSourcesChanged as String? {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(enabledSourcesDidChange(_:)),
                name: Notification.Name(name),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    @objc private func enabledSourcesDidChange(_ notification: Notification) {
        MainActor.assumeIsolated { InputMethodSourcePreferences.shared.invalidate(); reload() }
    }

    func reload() {
        sources = sourcesProvider()
        refreshStatuses()
    }

    private func refreshStatuses() {
        escapeStatus = actions?.escapeResetStatus ?? .off
        textFocusStatus = actions?.textFocusResetStatus ?? .off
        windowSwitchStatus = actions?.windowSwitchResetStatus ?? .off
        windowSwitchStalledApp = windowSwitchStatus == .active ? actions?.windowSwitchStalledApp : nil
        inputMethodInstallationStatus = actions?.inputMethodInstallationStatus ?? .init()
        inputMethodOperationRunning = actions?.isInputMethodOperationRunning ?? false
        inputMethodRoutingStatus = actions?.inputMethodRoutingStatus ?? .off
        wrongLanguageStatus = actions?.wrongLanguageStatus ?? .off
        wrongLanguageModelMissing = actions?.isWrongLanguageModelMissing ?? false
        launchAtLogin = actions?.isLaunchAtLoginEnabled ?? false
        systemIndicatorHidden = actions?.isSystemInputIndicatorHidden ?? false
    }

    // MARK: Bindings

    func binding<Value>(_ keyPath: WritableKeyPath<KeyHueSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.store.update { $0[keyPath: keyPath] = value } }
        )
    }

    func colorBinding(_ target: ColorTarget) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(target.color(in: self.settings))) },
            set: { color in
                guard let rgba = NSColor(color).rgbaColor else { return }
                self.store.update { target.setColor(rgba, in: &$0) }
            }
        )
    }

    var defaultSourceBinding: Binding<String> {
        Binding(
            get: { self.settings.defaultSourceID ?? "" },
            set: { id in self.store.update { $0.defaultSourceID = id.isEmpty ? nil : id } }
        )
    }

    var escapeBinding: Binding<Bool> {
        Binding(get: { self.settings.resetOnEscape }, set: { self.actions?.setResetOnEscape($0) })
    }

    /// 창 전환 동작은 손쉬운 사용 권한 안내가 필요하므로 actions를 거친다.
    var windowSwitchBinding: Binding<SwitchBehavior> {
        Binding(get: { self.settings.onWindowSwitch }, set: { self.actions?.setOnWindowSwitch($0) })
    }

    var inputMethodEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.integrateInputMethod }, set: { self.actions?.setInputMethodEnabled($0) })
    }

    func installInputMethod() { actions?.installInputMethod() }
    func uninstallInputMethod() { actions?.uninstallInputMethod() }
    func openInputSources() { actions?.openInputSourceSettings() }

    var inputMethodRoutingBinding: Binding<Bool> {
        Binding(get: { self.settings.routeInputMethodPair }, set: { self.actions?.setInputMethodRouting($0) })
    }

    var isInputMethodAvailable: Bool { InputMethodIntegration.isAvailable(in: sources) }

    /// 입력기 항목 상태. 메뉴와 같은 규칙을 쓴다(`InputMethodMenuState`).
    var inputMethodMenu: InputMethodMenuState {
        InputMethodMenuState(installation: inputMethodInstallationStatus, isBusy: inputMethodOperationRunning,
                             settings: settings, sources: sources, routingStatus: inputMethodRoutingStatus)
    }

    /// 기본 입력 소스 선택 목록. 메뉴와 같은 규칙을 쓴다(`DefaultSourceMenu`).
    var defaultSourceMenu: DefaultSourceMenu { DefaultSourceMenu(settings: settings, sources: sources) }

    func pauseInputMethodIntegration() { actions?.pauseInputMethodIntegration() }

    // MARK: Input method correction (ADR 0064)

    /// The input method reads the mode while it is in use.
    var isCorrectionEditable: Bool { settings.integrateInputMethod }

    var excludedAppsAreDefault: Bool { settings.correctionExcludedApps == InputMethodCorrection.defaultExcludedApps }

    func addExcludedApps(_ bundleIDs: [String]) {
        store.update { settings in
            for id in bundleIDs where !id.isEmpty && !settings.correctionExcludedApps.contains(id) {
                settings.correctionExcludedApps.append(id)
            }
        }
    }

    func removeExcludedApp(_ bundleID: String) {
        store.update { $0.correctionExcludedApps.removeAll { $0 == bundleID } }
    }

    func restoreDefaultExcludedApps() {
        store.update { $0.correctionExcludedApps = InputMethodCorrection.defaultExcludedApps }
    }

    /// The installed app's name, or the bundle ID when it is not installed.
    func appName(for bundleID: String) -> String {
        CorrectionFeedbackStore.appName(for: bundleID)
    }

    // MARK: Correction feedback (ADR 0065)

    func excludeFailedApp(_ bundleID: String) {
        addExcludedApps([bundleID])
        feedback.clearFailures(app: bundleID)
    }

    /// ADR 0067: the input method asks macOS for its own Accessibility access
    /// (it erases words in terminals with keys); the settings pane opens too.
    func allowTerminalFixing(_ bundleID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(InputMethodCorrection.requestKeyPermission), object: nil, userInfo: nil, deliverImmediately: true)
        feedback.clearFailures(app: bundleID)
        openAccessibility()
    }

    /// The user's "this was wrong": never correct this word, and drop the entry.
    func neverCorrect(_ entry: UndoneCorrection) {
        store.update { settings in
            if !settings.correctionIgnoredWords.contains(entry.original) {
                settings.correctionIgnoredWords.append(entry.original)
            }
        }
        feedback.removeUndone(entry)
    }

    func removeIgnoredWord(_ word: String) {
        store.update { $0.correctionIgnoredWords.removeAll { $0 == word } }
    }

    /// Turning recording off deletes the file.
    var recordUndoneBinding: Binding<Bool> {
        Binding(get: { self.settings.recordUndoneCorrections }, set: { enabled in
            self.store.update { $0.recordUndoneCorrections = enabled }
            if enabled { self.feedback.reloadUndone() } else { self.feedback.clearUndone() }
        })
    }

    /// Shows what will be published and opens the prefilled issue only if the user agrees.
    func confirmReport(_ url: URL?, summary: String) {
        guard let url else { return }
        let alert = NSAlert()
        alert.messageText = L("Open a Public GitHub Issue?")
        alert.informativeText = L("KeyHue doesn't send anything itself. Your browser opens a prefilled issue that anyone can read; review and edit it before you submit:") + "\n\n" + summary
        alert.addButton(withTitle: L("Open in Browser"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    func chooseExcludedApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        addExcludedApps(panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    var wrongLanguageBinding: Binding<Bool> {
        Binding(get: { self.settings.warnOnWrongLanguage }, set: { self.actions?.setWarnOnWrongLanguage($0) })
    }

    /// 두벌식과 QWERTY 영문 배열이 둘 다 켜져 있을 때만 보인다. 켜 둔 채 입력 소스를 지웠으면 끌 수 있게 계속 보인다.
    var showsWrongLanguageOption: Bool {
        settings.warnOnWrongLanguage || MistypeSupport.isAvailable(enabledSourceIDs: sources.map(\.id))
    }

    /// 켜 두었지만 메시지도 끄고 막대도 숨겨 경고가 아무 데도 보이지 않는다.
    var wrongLanguageWarningIsInvisible: Bool {
        settings.warnOnWrongLanguage && !settings.wrongLanguageShowsMessage && !settings.showStateBar
    }

    var textFocusBinding: Binding<Bool> {
        Binding(get: { self.settings.resetOnTextFocusLoss }, set: { self.actions?.setResetOnTextFocusLoss($0) })
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { self.launchAtLogin },
            set: { enabled in
                self.actions?.setLaunchAtLogin(enabled)
                self.refreshStatuses()
            }
        )
    }

    /// macOS 설정이라 KeyHue 설정에 저장하지 않고 실제 값을 읽는다(창을 열 때마다 다시 읽음).
    var systemIndicatorBinding: Binding<Bool> {
        Binding(
            get: { self.systemIndicatorHidden },
            set: { hidden in
                self.actions?.setSystemInputIndicatorHidden(hidden)
                self.refreshStatuses()
            }
        )
    }

    // MARK: Actions

    /// 켜진 입력 소스 중 이름이 같은 것이 있는지(그때만 내부 ID를 보여 구분한다).
    func hasDuplicateName(_ source: InputSourceInfo) -> Bool {
        sources.filter { $0.displayName == source.displayName }.count > 1
    }

    func isCustomized(_ source: InputSourceInfo) -> Bool {
        settings.sourceColors[source.id] != nil
    }

    func resetColor(_ source: InputSourceInfo) {
        store.update { $0.resetColor(for: source) }
    }

    func resetAllColors() {
        store.update { $0.resetColors() }
    }

    func forgetPerAppInputs() {
        actions?.forgetPerAppInputs()
    }

    func openInputMonitoring() {
        actions?.openInputMonitoringSettings()
    }

    func openAccessibility() {
        actions?.openAccessibilitySettings()
    }

    func showLogFile() {
        actions?.showLogFile()
    }

    var automaticDefaultName: String {
        defaultSourceMenu.automaticName ?? L("No Available Input Source")
    }

    var resolvedDefaultSource: InputSourceInfo? {
        InputMethodIntegration.defaultSource(settings: settings, sources: sources)
    }

    var resolvedDefaultName: String {
        resolvedDefaultSource?.displayName ?? L("Default Input Source")
    }

    var unavailableDefaultSourceID: String? {
        defaultSourceMenu.showsUnavailableChoice ? settings.defaultSourceID : nil
    }

    var defaultSourceNotice: String? {
        guard let source = resolvedDefaultSource else {
            return L("No default input source is available. Add an input source in System Settings › Keyboard › Input Sources. Automatic switching will keep the current input source.")
        }
        if unavailableDefaultSourceID != nil {
            return L("The selected input source is unavailable. Automatic switching will use %@ instead.", source.displayName)
        }
        return nil
    }
}

@MainActor
final class SettingsWindowController {
    func refreshInputMethodStatus() { model.reload() }
    private let model: SettingsModel
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// 창이 열리고 닫힐 때. Dock 표시를 끈 상태에서도 열려 있는 동안은 Dock에 보이게 한다(ADR 0038).
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        onVisibilityChange?(true)
        // 창을 닫을 때 포커스를 돌려주려고 앱을 숨긴다(ADR 0038). 숨긴 앱의 창은 앞으로 가져와도 보이지 않으므로 먼저 푼다.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showUpdates() {
        model.selectedTab = .general
        show()
    }

    func updateTitle() {
        window?.title = L("KeyHue Settings")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = L("KeyHue Settings")
        // 본문 배경을 제목 막대 밑까지 늘려 한 가지 색으로 잇는다. 탭 막대 위에 구분선이나 색 차이가 생기지 않게 한다.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.center()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onVisibilityChange?(false) }
        }
        return window
    }
}

// MARK: - Views

/// 탭마다 내용 길이를 비슷하게 맞춘다. 한 탭이 길어져 스크롤되지 않게 표시 관련 항목은 "모양"에 모은다(ADR 0038).
enum SettingsTab: String, CaseIterable {
    case general
    case appearance
    case sources
    case automation
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var tab: SettingsTab { model.selectedTab }

    init(model: SettingsModel, tab: SettingsTab = .general) {
        self.model = model
        model.selectedTab = tab
    }

    static let size = CGSize(width: 540, height: 640)

    /// SwiftUI TabView는 내용 둘레에 테두리 상자를 그려, 탭이 제목 막대에 붙고 탭 아래에 배경색이 다른 띠가 생긴다.
    /// 탭은 분할 컨트롤로 직접 그리고, 탭과 내용이 같은 창 배경을 쓰게 한다(ADR 0038).
    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $model.selectedTab)
                .frame(width: 440)
                .padding(.top, 14)
                .padding(.bottom, 4)

            Group {
                switch tab {
                case .general: GeneralSettingsView(model: model, updates: model.updates)
                case .appearance: AppearanceSettingsView(model: model)
                case .sources: InputSourcesSettingsView(model: model)
                case .automation: AutomationSettingsView(model: model)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}

/// 설정 탭 막대. SwiftUI의 분할 컨트롤은 칸을 글자 길이에 맞춰 나눠 긴 이름이 비좁아 보이므로,
/// AppKit 분할 컨트롤로 네 칸을 같은 너비로 나눈다.
private struct SettingsTabBar: NSViewRepresentable {
    @Binding var selection: SettingsTab

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: SettingsTab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentDistribution = .fillEqually
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        // 언어를 바꾸면 다시 그려지므로 제목도 여기서 갱신한다.
        for (index, tab) in SettingsTab.allCases.enumerated() {
            control.setLabel(tab.title, forSegment: index)
        }
        control.selectedSegment = SettingsTab.allCases.firstIndex(of: selection) ?? 0
    }

    final class Coordinator: NSObject {
        var selection: Binding<SettingsTab>

        init(selection: Binding<SettingsTab>) {
            self.selection = selection
        }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            let tabs = SettingsTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .sources: return L("Input Sources")
        case .automation: return L("Automation")
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: model.binding(\.appLanguage)) {
                    Text(L("System Default")).tag(AppLanguage.system)
                    ForEach(AppLanguage.allCases.filter { $0 != .system }, id: \.self) { language in
                        Text(language.nativeName ?? language.rawValue).tag(language)
                    }
                }
            } footer: {
                FooterText(L("Some system-provided text, such as input source names, follows the macOS language."))
            }

            Section {
                Toggle(L("Show in Dock"), isOn: model.binding(\.showDockIcon))
                Toggle(L("Launch at Login"), isOn: model.launchAtLoginBinding)
            } footer: {
                FooterText(L("When Show in Dock is off, KeyHue stays in the menu bar and appears in the Dock only while this window is open."))
            }

            Section {
                HStack {
                    Text(L("Current Version"))
                    Spacer()
                    Text(updates.currentVersion).foregroundStyle(.secondary)
                    Button(L("Check for Updates…")) { Task { await updates.checkNow() } }
                        .disabled(updates.state.isChecking)
                }
                Toggle(L("Automatically Check for Updates"), isOn: model.binding(\.automaticallyChecksForUpdates))
                if let url = updates.releaseURL {
                    Link(L("Download New Version v%@…", updates.state.availableVersion ?? ""), destination: url)
                }
            } header: {
                Text(L("Updates"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    FooterText(updates.statusText)
                    HStack(spacing: 4) {
                        Text(L("Last Checked") + ":")
                        if let date = updates.state.lastChecked {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text(L("Never"))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    FooterText(L("Checks GitHub once a day. Download and install updates yourself from the release page."))
                }
            }

            Section {
                Button(L("Show Log File"), action: model.showLogFile)
            } footer: {
                FooterText(L("KeyHue keeps a log of app and window switches and input source changes. Attach it when reporting a problem. It never contains what you type."))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L("State Bar")) {
                Toggle(L("Show State Bar"), isOn: model.binding(\.showStateBar))
                Picker(L("Bar Position"), selection: model.binding(\.barPosition)) {
                    ForEach(BarPosition.allCases, id: \.self) { position in
                        Text(StatusBarController.title(for: position)).tag(position)
                    }
                }
                Picker(L("Bar Thickness"), selection: model.binding(\.barHeight)) {
                    ForEach(KeyHueSettings.barHeightChoices, id: \.self) { height in
                        Text("\(Int(height))px").tag(height)
                    }
                }
                LabeledContent(L("Bar Opacity")) {
                    HStack {
                        Slider(value: model.binding(\.barOpacity), in: KeyHueSettings.barOpacityRange, step: 0.1)
                        Text("\(Int((model.settings.barOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker(L("Displays"), selection: model.binding(\.displayPolicy)) {
                    Text(L("All Displays")).tag(DisplayPolicy.allScreens)
                    Text(L("Active Display Only")).tag(DisplayPolicy.activeScreen)
                }
            }

            Section {
                Toggle(L("Tint Menu Bar Icon"), isOn: model.binding(\.tintMenuBarIcon))
                Toggle(L("Show HUD on Change"), isOn: model.binding(\.showHUD))
            } header: {
                Text(L("Indicators"))
            } footer: {
                FooterText(L("The HUD appears the moment you switch. It hides as soon as you start typing only when Switch to %@ on ESC is on, because that uses Input Monitoring.", model.resolvedDefaultName))
            }

            Section {
                Toggle(L("Hide macOS Input Source Indicator"), isOn: model.systemIndicatorBinding)
            } footer: {
                FooterText(L("The badge macOS shows next to the cursor when you switch input sources. This is a macOS setting that applies to all apps right away and stays after you remove KeyHue."))
            }
        }
        .formStyle(.grouped)
    }
}

private struct InputSourcesSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.sources, id: \.id) { source in
                    // 내부 ID는 이름이 겹칠 때만 보여 구분하고, 평소에는 마우스를 올리면 보인다.
                    ColorRow(
                        title: source.displayName,
                        subtitle: model.hasDuplicateName(source) ? source.id : nil,
                        color: model.colorBinding(.source(source)),
                        onReset: model.isCustomized(source) ? { model.resetColor(source) } : nil
                    )
                    .help(source.id)
                }
                ColorRow(
                    title: L("Caps Lock"),
                    subtitle: L("Shown instead of the input source color while Caps Lock is on."),
                    color: model.colorBinding(.capsLock),
                    onReset: nil
                )
            } header: {
                Text(L("Colors"))
            } footer: {
                FooterText(L("Each input source enabled in System Settings › Keyboard › Input Sources gets its own color."))
            }

            Section {
                Button(L("Reset All Colors"), action: model.resetAllColors)
            }

            Section {
                Picker(L("Default Input Source"), selection: model.defaultSourceBinding) {
                    Text(L("Automatic (%@)", model.automaticDefaultName)).tag("")
                    if let id = model.unavailableDefaultSourceID {
                        Text(L("Unavailable Input Source")).tag(id).disabled(true)
                    }
                    ForEach(model.defaultSourceMenu.choices, id: \.id) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
            } footer: {
                FooterText(L("Automatic switching (app or window switch, ESC, leaving a text field) selects this input source."))
                if let notice = model.defaultSourceNotice {
                    FooterText(notice)
                }
            }

            Section {
                Text(L("KeyHue follows the input source that macOS reports. Modes switched inside a single input method without changing the input source (for example Shift in some Chinese input methods) cannot be detected."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ColorRow: View {
    let title: String
    let subtitle: String?
    let color: Binding<Color>
    let onReset: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let onReset {
                Button(L("Reset"), action: onReset)
                    .buttonStyle(.link)
            }
            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

private struct AutomationSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            // 앱·창을 바꿀 때 각각 하나만 고른다(ADR 0029)
            Section {
                if let notice = model.defaultSourceNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker(L("When Switching Apps"), selection: model.binding(\.onAppSwitch)) {
                    behaviorChoices
                }
                Picker(L("When Switching Windows in the Same App"), selection: model.windowSwitchBinding) {
                    behaviorChoices
                }
                if let app = model.windowSwitchStalledApp {
                    Label(L("%@ isn't answering Accessibility requests, so KeyHue can't see its window switches. Switching to another app and back tries again.", app),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if model.windowSwitchStatus == .needsPermission {
                    PermissionRow(message: L("Accessibility access is required."), action: model.openAccessibility)
                }
                if model.settings.rememberInputPerApp || model.settings.rememberInputPerWindow {
                    Button(L("Forget Remembered Inputs"), action: model.forgetPerAppInputs)
                }
            } footer: {
                FooterText(L("Restore brings back the input source you last used in that app or window; apps and windows KeyHue hasn't seen switch to %@. Coming back from another app follows When Switching Apps, so with Keep As Is the front window keeps the current input source. Windows are remembered only until KeyHue quits. The window option needs Accessibility access: KeyHue only notices that the main window changed and never reads window titles or contents.", model.resolvedDefaultName))
            }

            Section {
                Toggle(L("Switch to %@ on ESC", model.resolvedDefaultName), isOn: model.escapeBinding)
                if model.escapeStatus == .needsPermission {
                    PermissionRow(message: L("Input Monitoring access is required."), action: model.openInputMonitoring)
                }
            } footer: {
                FooterText(L("KeyHue only checks whether the pressed key is ESC. It never reads, stores, or sends what you type."))
            }

            Section {
                Toggle(L("Switch to %@ When Leaving Text Field", model.resolvedDefaultName), isOn: model.textFocusBinding)
                if model.textFocusStatus == .needsPermission {
                    PermissionRow(message: L("Accessibility access is required."), action: model.openAccessibility)
                }
            } header: {
                Text(L("Experimental"))
            } footer: {
                FooterText(L("Experimental. Requires Accessibility access. KeyHue only reads the focused element's role, never its contents."))
            }

            let inputMethod = model.inputMethodMenu
            Section {
                Toggle(L("Use KeyHue Input Method (Experimental)"), isOn: model.inputMethodEnabledBinding)
                    .disabled(!inputMethod.isIntegrationEnabled)
                if model.inputMethodOperationRunning {
                    ProgressView(L("Managing Input Method…"))
                } else {
                    Button(inputMethod.installAction.title, action: model.installInputMethod)
                        .disabled(!inputMethod.isInstallEnabled)
                    if !inputMethod.isUninstallHidden {
                        if model.inputMethodInstallationStatus.isInstalled {
                            Text(L("Input Method Installed")).font(.callout).foregroundStyle(.secondary)
                        }
                        Button(L("Uninstall Input Method"), action: model.uninstallInputMethod)
                    }
                }
                if !model.inputMethodInstallationStatus.hasPayload {
                    FooterText(L("This copy of KeyHue does not include its input method. Install the packaged KeyHue app."))
                }
                if !inputMethod.isNoticeHidden {
                    Label(L("Enable both KeyHue input modes in System Settings first."), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                    Button(L("Open Input Source Settings"), action: model.openInputSources)
                }
                Toggle(L("Keep KeyHue Korean/English Modes (Experimental)"), isOn: model.inputMethodRoutingBinding)
                    .disabled(!inputMethod.isRoutingEnabled)
                if !inputMethod.isRoutingPermissionHidden {
                    PermissionRow(message: L("Input Monitoring access is required."), action: model.openInputMonitoring)
                }
                if !inputMethod.isRecoveryHidden {
                    Button(L("Pause Integration and Switch to ABC"), action: model.pauseInputMethodIntegration)
                }
            } header: {
                Text(L("Experimental · KeyHue Input Method"))
            } footer: {
                FooterText(L("KeyHue includes its input method. Turning this on installs or updates it for your user account. Add both KeyHue modes in System Settings → Keyboard → Text Input to start Korean/English integration. Before uninstalling, remove both modes there; uninstall removes only the input method and keeps your KeyHue settings."))
                FooterText(L("While both KeyHue modes are enabled, automatic or ABC defaults and remembered ABC use KeyHue English, and 2-Set Korean uses KeyHue Korean. When integration is off or a mode is missing, remembered KeyHue modes use ABC and 2-Set Korean again. Your saved settings remain unchanged. If selection fails, the original policy is used."))
                FooterText(L("ABC selected from a KeyHue mode is redirected to the other KeyHue mode, including manual ABC selection. Other languages are kept. Use Pause Integration and Switch to ABC to leave the pair. Very fast typing may arrive before macOS reports the switch."))
                FooterText(L("KeyHue observes input source changes for every switching method. Input Monitoring lets it cancel a pending switch when typing begins. It never reads, stores, or sends text for this option."))
            }

            // ADR 0064: the input method reads these; editable while the input method is used.
            Section {
                Picker(L("Fix Words Typed in the Wrong Input Mode"), selection: model.binding(\.inputMethodCorrection)) {
                    Text(L("Off")).tag(CorrectionMode.off)
                    Text(L("When I Switch Input Modes")).tag(CorrectionMode.manual)
                    Text(L("Automatically at Space")).tag(CorrectionMode.automatic)
                }
                DisclosureGroup(L("Apps That Are Never Changed")) {
                    ForEach(model.settings.correctionExcludedApps, id: \.self) { bundleID in
                        HStack {
                            Text(model.appName(for: bundleID))
                            Spacer()
                            Button(L("Remove")) { model.removeExcludedApp(bundleID) }
                        }
                    }
                    HStack {
                        Button(L("Add App…"), action: model.chooseExcludedApps)
                        Button(L("Restore Defaults"), action: model.restoreDefaultExcludedApps)
                            .disabled(model.excludedAppsAreDefault)
                    }
                }
                CorrectionFeedbackView(model: model, feedback: model.feedback)
            } header: {
                Text(L("Experimental · Word Fixing"))
            } footer: {
                FooterText(L("Fixes the word you just typed in the wrong input mode. When I Switch Input Modes: switch right after the word and KeyHue fixes it, both ways: dkssud → 안녕 when you switch to Korean, ㅗ디ㅣㅐ → hello when you switch to English. Automatically at Space: Korean typed in English mode is fixed when you press Space, and KeyHue switches to Korean; English typed in Korean mode is still fixed when you switch. Press Delete right away to undo. Password fields and the apps above are never changed; with Automatically at Space, add code editors here if identifiers get changed."))
                FooterText(L("In terminals, words are fixed only when you switch. KeyHue erases the word with Delete keys and types the fix, which needs Accessibility access for the KeyHue input method; macOS asks the first time. The word stays in the input method's memory only; nothing is saved or sent."))
            }
            .disabled(!model.isCorrectionEditable)

            if model.showsWrongLanguageOption {
                Section {
                    Toggle(L("Warn When Korean and English Are Mixed Up"), isOn: model.wrongLanguageBinding)
                    if model.wrongLanguageStatus == .needsPermission {
                        PermissionRow(message: L("Input Monitoring access is required."), action: model.openInputMonitoring)
                    }
                    Toggle(L("Show a Message"), isOn: model.binding(\.wrongLanguageShowsMessage))
                        .disabled(!model.settings.warnOnWrongLanguage)
                        .padding(.leading, 16)
                    if model.wrongLanguageModelMissing {
                        Label(L("KeyHue couldn't load its Korean syllable model, so this option isn't working. Reinstalling KeyHue should fix it."),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if model.wrongLanguageWarningIsInvisible {
                        Label(L("The bar is hidden, so warnings won't be visible. Show the bar or turn on Show a Message."),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    // 한국어 사용자를 위한 기능임을 다른 언어 사용자에게도 분명히 한다
                    Text(L("Experimental · Korean Input"))
                } footer: {
                    FooterText(L("For Korean (2-Set) users, together with a QWERTY English layout. When a word looks like it's being typed in the other mode (dkssud → 안녕, ㅗ디ㅣㅐ → hello), KeyHue lets you know, usually within the first few keys: the bar blinks in that language's color and, if Show a Message is on, a message shows the word in that language. Nothing is changed or switched. KeyHue reads only key positions, keeps the current word in memory, and discards it when the word ends. Requires Input Monitoring access."))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var behaviorChoices: some View {
        ForEach(SwitchBehavior.allCases, id: \.self) { behavior in
            Text(StatusBarController.title(for: behavior, defaultName: model.resolvedDefaultName)).tag(behavior)
        }
    }
}

/// ADR 0065: exception words, undone fixes (only when recorded) and apps where fixing failed.
private struct CorrectionFeedbackView: View {
    let model: SettingsModel
    @ObservedObject var feedback: CorrectionFeedbackStore

    var body: some View {
        if !model.settings.correctionIgnoredWords.isEmpty {
            DisclosureGroup(L("Words That Are Never Changed")) {
                ForEach(model.settings.correctionIgnoredWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(L("Remove")) { model.removeIgnoredWord(word) }
                    }
                }
            }
        }
        Toggle(L("Record Undone Fixes"), isOn: model.recordUndoneBinding)
        if model.settings.recordUndoneCorrections, !feedback.undone.isEmpty {
            DisclosureGroup(L("Undone Fixes")) {
                ForEach(feedback.undone, id: \.self) { entry in
                    HStack {
                        Text("\(entry.original) → \(entry.corrected)")
                        Text(model.appName(for: entry.app)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Never Fix This Word")) { model.neverCorrect(entry) }
                        Button(L("Report")) {
                            model.confirmReport(feedback.reportURL(for: entry),
                                                summary: "\(entry.original) → \(entry.corrected) · \(entry.app) · \(entry.mode.rawValue)")
                        }
                        Button(L("Delete")) { feedback.removeUndone(entry) }
                    }
                }
                Button(L("Delete All"), action: feedback.clearUndone)
            }
        }
        if !feedback.failures.isEmpty {
            DisclosureGroup(L("Apps Where Fixing Failed")) {
                ForEach(feedback.failures, id: \.app) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.appName(for: record.app))
                            Text(L("%@ times · %@", String(record.count), Self.reasonText(record.lastReason)))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if record.lastReason == .keyPermission {
                            Button(L("Allow…")) { model.allowTerminalFixing(record.app) }
                        }
                        Button(L("Exclude")) { model.excludeFailedApp(record.app) }
                        Button(L("Try Again")) { feedback.clearFailures(app: record.app) }
                        Button(L("Report")) {
                            model.confirmReport(feedback.reportURL(for: record),
                                                summary: "\(record.app) · \(record.lastReason.rawValue) · \(record.count)")
                        }
                    }
                }
            }
        }
        FooterText(L("When on, KeyHue keeps fixes you undid right away (what you typed, what it became, and the app) on this Mac only, up to 50. Turning it off deletes them. Reports open in your browser, and only for what you choose."))
    }

    static func reasonText(_ reason: CorrectionFailure) -> String {
        switch reason {
        case .textUnavailable: return L("The app didn't report the text")
        case .replacementIgnored: return L("The app ignored the replacement")
        case .unexpectedResult: return L("The result was different")
        case .modeNotApplied: return L("Korean mode wasn't applied")
        case .keyPermission: return L("The input method needs Accessibility access")
        }
    }
}

private struct PermissionRow: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            Button(L("Grant Access…"), action: action)
        }
    }
}

/// Form 섹션 footer. 여러 줄일 때 오른쪽 정렬되지 않도록 왼쪽에 맞춘다.
private struct FooterText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true) // 긴 문장이 한 줄로 잘리지 않도록
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
