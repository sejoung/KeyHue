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
    private weak var actions: SettingsActions?
    /// Correction failures and undone corrections (ADR 0065).
    let feedback: CorrectionFeedbackStore
    /// 켜진 입력 소스 목록. 스크린샷 렌더링에서는 예시 목록으로 바꾼다.
    private let sourcesProvider: @MainActor () -> [InputSourceInfo]

    init(
        store: SettingsStore,
        actions: SettingsActions,
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
        actions?.refreshFeatureStatuses()
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

    func installInputMethod() { actions?.installInputMethod() }
    func uninstallInputMethod() { actions?.uninstallInputMethod() }
    func openInputSources() { actions?.openInputSourceSettings() }

    var inputMethodRoutingBinding: Binding<Bool> {
        Binding(get: { self.settings.routeInputMethodPair }, set: { self.actions?.setInputMethodRouting($0) })
    }

    /// 입력기 항목 상태. 메뉴와 같은 규칙을 쓴다(`InputMethodMenuState`).
    var inputMethodMenu: InputMethodMenuState {
        InputMethodMenuState(installation: inputMethodInstallationStatus, isBusy: inputMethodOperationRunning,
                             settings: settings, sources: sources, routingStatus: inputMethodRoutingStatus)
    }

    /// 기본 입력 소스 선택 목록. 메뉴와 같은 규칙을 쓴다(`DefaultSourceMenu`).
    var defaultSourceMenu: DefaultSourceMenu { DefaultSourceMenu(settings: settings, sources: sources) }

    func pauseInputMethodIntegration() { actions?.pauseInputMethodIntegration() }

    /// ADR 0069: the one next step the input method section shows.
    func perform(_ step: InputMethodMenuState.NextStep) {
        switch step {
        case .install: actions?.installInputMethod()
        case .openInputSources: actions?.openInputSourceSettings()
        }
    }

    // MARK: Input method correction (ADR 0064)

    /// The input method reads the mode while it is in use.
    var isCorrectionEditable: Bool { settings.integrateInputMethod }

    var excludedAppsAreDefault: Bool { settings.correctionExcludedApps == InputMethodCorrection.defaultExcludedApps }

    /// ADR 0068: the shortcut fixes without the detector. Exception words and
    /// undone fixes steer only automatic fixing.
    var showsDetectorOptions: Bool { settings.inputMethodCorrection == .automatic }

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

    /// ADR 0073: KeyHue posts the keys that erase a terminal word, so it asks
    /// macOS for its own Accessibility access; the settings pane opens too.
    func allowTerminalFixing(_ bundleID: String) {
        _ = CGRequestPostEventAccess()
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
