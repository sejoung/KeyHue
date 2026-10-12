import AppKit
import KeyHueCore
import SwiftUI

/// 설정 창의 상태. SettingsStore를 SwiftUI에 연결한다(ADR 0015).
@MainActor
final class SettingsModel: NSObject, ObservableObject {
    let updates: UpdateChecker
    @Published var selectedTab: SettingsTab = .general
    @Published private(set) var settings: KeyHueSettings
    @Published private(set) var sources: [InputSourceInfo] = []
    /// 창 전환 알림에 붙지 못한 앱은 창 옵션이 동작 중일 때만 담는다.
    @Published private(set) var statuses = FeatureStatuses()
    @Published private(set) var system = SystemSettingsStatus()

    private let store: SettingsStore
    private weak var actions: SettingsActions?
    /// Correction failures and undone corrections (ADR 0065).
    let feedback: CorrectionFeedbackStore
    /// 켜진 입력 소스 목록. 스크린샷 렌더링에서는 예시 목록으로 바꾼다.
    private let sourcesProvider: @MainActor () -> [InputSourceInfo]
    private let dialogs: SettingsDialogs

    init(
        store: SettingsStore,
        actions: SettingsActions,
        updates: UpdateChecker = UpdateChecker(),
        feedback: CorrectionFeedbackStore = .shared,
        dialogs: SettingsDialogs = SystemSettingsDialogs(),
        sourcesProvider: @escaping @MainActor () -> [InputSourceInfo] = InputSourceController.enabledSources
    ) {
        self.store = store
        self.dialogs = dialogs
        self.feedback = feedback
        self.updates = updates
        self.actions = actions
        self.sourcesProvider = sourcesProvider
        self.settings = store.settings
        super.init()
        store.addObserver { [weak self] _, new in self?.settings = new }
        // 입력 소스를 추가/삭제하면 InputSourceMonitor가 알리고 AppDelegate가 `reload()`를 부른다(ADR 0023).
    }

    /// 앱이 설정 변경을 다 반영한 뒤(감시 연결 갱신) 부른다. 그래서 여기서 읽는 상태는 새 상태이고,
    /// 저장소 관찰자의 등록 순서에 기대지 않는다.
    func settingsApplied(from old: KeyHueSettings, to new: KeyHueSettings) {
        // 상태 조회는 시스템 호출(로그인 항목, macOS 설정, 입력기 파일)이라 무겁다. 창이 열려 있고
        // 모양 말고 다른 것이 바뀌었을 때만 읽는다. 색 선택기·슬라이더는 초당 여러 번 바꾼다.
        if isShown, !new.differsOnlyInAppearance(from: old) { refreshStatuses() }
    }

    /// 창이 열려 있다. 닫혀 있는 동안의 변경은 다음에 열 때 `reload()`가 읽는다.
    var isShown = false

    /// 창을 열 때·입력 소스가 바뀔 때: 모니터 연결을 갱신한 뒤 상태를 읽는다.
    /// 설정 변경은 AppDelegate가 바뀐 항목에 맞춰 이미 갱신하므로 상태만 다시 읽는다.
    func reload() {
        sources = sourcesProvider()
        actions?.refreshFeatureStatuses()
        refreshStatuses()
    }

    private func refreshStatuses() {
        var statuses = actions?.featureStatuses ?? FeatureStatuses()
        if statuses.windowSwitch != .active { statuses.windowSwitchStalledApp = nil }
        self.statuses = statuses
        system = actions?.systemSettingsStatus ?? SystemSettingsStatus()
    }

    // MARK: Bindings

    /// A setting that needs no permission. One that does uses `actionBinding`, which asks first.
    /// The menu bar menu follows the same rule (`StatusBarController`).
    func binding<Value>(_ keyPath: WritableKeyPath<KeyHueSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.store.update { $0[keyPath: keyPath] = value } }
        )
    }

    func colorBinding(_ target: ColorTarget) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(target.color(in: self.displaySettings))) },
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

    /// 권한 안내가 필요한 설정은 actions를 거친다. 거절하면 값이 그대로라 설정 알림이 오지 않으므로,
    /// 어느 쪽이든 SwiftUI가 값을 다시 읽게 한다. 그러지 않으면 거절한 스위치가 켜진 채로 그려진다.
    private func actionBinding<Value>(_ keyPath: KeyPath<KeyHueSettings, Value>,
                                      _ set: @escaping (SettingsActions, Value) -> Void) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in
            if let actions = self.actions { set(actions, value) }
            self.objectWillChange.send()
        })
    }

    var escapeBinding: Binding<Bool> {
        actionBinding(\.resetOnEscape) { $0.setResetOnEscape($1) }
    }

    /// 창 전환 동작은 손쉬운 사용 권한 안내가 필요하므로 actions를 거친다.
    var windowSwitchBinding: Binding<SwitchBehavior> {
        actionBinding(\.onWindowSwitch) { $0.setOnWindowSwitch($1) }
    }

    func installInputMethod() { actions?.installInputMethod() }
    func uninstallInputMethod() { actions?.uninstallInputMethod() }

    var inputMethodRoutingBinding: Binding<Bool> {
        actionBinding(\.routeInputMethodPair) { $0.setInputMethodRouting($1) }
    }

    /// 입력기 항목 상태. 메뉴와 같은 규칙을 쓴다(`InputMethodMenuState`).
    var inputMethodMenu: InputMethodMenuState {
        InputMethodMenuState(installation: statuses.inputMethodInstallation, isBusy: statuses.isInputMethodOperationRunning,
                             settings: settings, sources: sources, routingStatus: statuses.inputMethodRouting)
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

    /// ADR 0081: recommend turning off macOS automatic capitalization while words are fixed.
    var showsAutoCapitalizationNotice: Bool {
        system.isAutoCapitalizationOn && isCorrectionEditable && settings.inputMethodCorrection != .off
    }

    func openKeyboardSettings() { actions?.openInputSourceSettings() }

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
        actions?.requestKeyPostingAccess()
        feedback.clearFailures(app: bundleID)
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
        guard let url, dialogs.confirmPublicReport(summary: summary) else { return }
        NSWorkspace.shared.open(url)
    }

    func chooseExcludedApps() {
        addExcludedApps(dialogs.chooseApps())
    }

    var wrongLanguageBinding: Binding<Bool> {
        actionBinding(\.warnOnWrongLanguage) { $0.setWarnOnWrongLanguage($1) }
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
        actionBinding(\.resetOnTextFocusLoss) { $0.setResetOnTextFocusLoss($1) }
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { self.system.isLaunchAtLoginEnabled },
            set: { enabled in
                self.actions?.setLaunchAtLogin(enabled)
                self.refreshStatuses()
            }
        )
    }

    /// macOS 설정이라 KeyHue 설정에 저장하지 않고 실제 값을 읽는다(창을 열 때마다 다시 읽음).
    var systemIndicatorBinding: Binding<Bool> {
        Binding(
            get: { self.system.isSystemInputIndicatorHidden },
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
