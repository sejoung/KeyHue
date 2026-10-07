import AppKit
import Foundation
import KeyHueCore
import KeyHueSystemLexicon
import SwiftUI
import Testing
@testable import KeyHueApp

/// 실제 macOS API를 쓰는 통합 테스트(ADR 0022). 화면이 있는 macOS 세션(로컬, GitHub macOS 러너)에서 돈다.

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
private func makeStore() -> SettingsStore {
    SettingsStore(defaults: makeTestDefaults())
}

// MARK: - State Bar 패널

@MainActor
@Suite("Overlay panels", .serialized)
struct OverlayControllerTests {
    private func settings(_ configure: (inout KeyHueSettings) -> Void = { _ in }) -> KeyHueSettings {
        var s = KeyHueSettings()
        configure(&s)
        return s
    }

    private func shown(_ overlay: OverlayController) -> [StateBarPanel] {
        overlay.panels.values.filter(\.isVisible)
    }

    @Test func onePanelPerScreenAtTheBottomEdge() {
        let overlay = OverlayController()
        overlay.start()
        let s = settings { $0.barHeight = 4 }
        overlay.apply(state: .source(.korean2Set), settings: s)
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }

        #expect(shown(overlay).count == NSScreen.screens.count)
        for screen in NSScreen.screens {
            let panel = overlay.panels[screen.displayID!]
            #expect(panel?.frame == ScreenGeometry.stateBarFrame(screenFrame: screen.frame, thickness: 4, position: .bottom))
        }
    }

    /// The log says what the bar showed where (2026-10-07: "the color did not change").
    @Test func diagnosticsNameEachScreenAndItsColor() throws {
        let overlay = OverlayController()
        overlay.start()
        let s = settings()
        overlay.apply(state: .source(.korean2Set), settings: s)
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }
        let id = try #require(NSScreen.screens.first?.displayID)
        let color = OverlayController.hex(NSColor(s.barColor(for: .source(.korean2Set))))
        #expect(overlay.diagnostics.contains("\(id):\(color)"))
        #expect(!overlay.diagnostics.contains("disconnected"))
        #expect(!overlay.diagnostics.contains("hidden"))
        overlay.apply(state: .source(.korean2Set), settings: settings { $0.showStateBar = false })
        #expect(overlay.diagnostics == "off")
        #expect(OverlayController.hex(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#FF7F00")
    }

    @Test func panelsNeverTakeInputOrFocus() throws {
        let overlay = OverlayController()
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings())
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }

        let panel = try #require(overlay.panels.values.first)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hasShadow)
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
    }

    @Test func colorFollowsStateAndOpacity() throws {
        let overlay = OverlayController()
        overlay.start()
        let s = settings { $0.barOpacity = 0.6 }
        overlay.apply(state: .source(.korean2Set), settings: s)
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }

        let color = try #require(overlay.panels.values.first?.backgroundColor.rgbaColor)
        let expected = s.barColor(for: .source(.korean2Set))
        #expect(abs(color.green - expected.green) < 0.01)
        #expect(abs(color.alpha - 0.6) < 0.01)

        overlay.apply(state: .capsLock, settings: s)
        let caps = try #require(overlay.panels.values.first?.backgroundColor.rgbaColor)
        #expect(abs(caps.red - s.capsLockColor.red) < 0.01)
    }

    @Test func positionAndHide() throws {
        let overlay = OverlayController()
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings { $0.barPosition = .top; $0.barHeight = 6 })
        let screen = try #require(NSScreen.screens.first)
        let panel = try #require(overlay.panels[screen.displayID!])
        #expect(panel.frame.maxY == screen.frame.maxY)
        #expect(panel.frame.height == 6)

        overlay.apply(state: .source(.abc), settings: settings { $0.showStateBar = false })
        #expect(shown(overlay).isEmpty)
    }

    @Test func activeScreenPolicyShowsOnePanel() {
        let overlay = OverlayController()
        overlay.start()
        overlay.setActiveScreen(NSScreen.main)
        overlay.apply(state: .source(.abc), settings: settings { $0.displayPolicy = .activeScreen })
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }
        #expect(shown(overlay).count == 1)
    }

    /// ADR 0063: 활성 모니터 정책의 막대는 넘겨받은 화면으로 옮겨 간다(같은 앱의 다른 모니터 창 포함).
    @Test func activeScreenPolicyMovesTheBarToEachFocusedScreen() {
        let overlay = OverlayController()
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings { $0.displayPolicy = .activeScreen; $0.barPosition = .bottom })
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }
        for screen in NSScreen.screens {
            overlay.setActiveScreen(screen)
            let visible = shown(overlay)
            #expect(visible.count == 1)
            #expect(visible.first?.frame == ScreenGeometry.stateBarFrame(screenFrame: screen.frame, thickness: 3, position: .bottom))
        }
    }

    @Test func wrongLanguageFlashBlinksThickerAndRestores() throws {
        // 잘못된 언어 경고(ADR 0041): 의도한 언어 색으로 굵게 깜빡인 뒤 지금 상태 색·두께로 돌아온다
        let clock = FakeScheduler()
        let overlay = OverlayController(scheduler: clock)
        overlay.start()
        let s = settings { $0.barHeight = 2 }
        overlay.apply(state: .source(.abc), settings: s)
        defer { overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false }) }
        let screen = try #require(NSScreen.screens.first)
        let panel = try #require(overlay.panels[screen.displayID!])
        let korean = s.color(for: .korean2Set)

        overlay.flash(color: korean)
        #expect(overlay.isFlashing)
        #expect(panel.frame.height == OverlayController.flashMinimumThickness)
        let on = try #require(panel.backgroundColor.rgbaColor)
        #expect(abs(on.green - korean.green) < 0.01 && abs(on.blue - korean.blue) < 0.01) // 바로 보인다

        clock.advance(by: OverlayController.flashOn)
        let off = try #require(panel.backgroundColor.rgbaColor)
        #expect(abs(off.blue - s.barColor(for: .source(.abc)).blue) < 0.01)

        // 깜빡이는 중 상태가 바뀌어도 깜빡임을 덮지 않고, 끝나면 새 상태 색으로 돌아온다
        overlay.apply(state: .capsLock, settings: s)
        clock.advance(by: 2)
        #expect(!overlay.isFlashing)
        #expect(panel.frame.height == 2)
        let restored = try #require(panel.backgroundColor.rgbaColor)
        #expect(abs(restored.red - s.capsLockColor.red) < 0.01)
    }

    @Test func barStaysWhenKeyHueIsHidden() throws {
        // 설정 창을 닫아 메뉴바 전용으로 돌아갈 때(NSApp.hide, ADR 0038), ⌘H "KeyHue 가리기",
        // 다른 앱의 "기타 가리기"는 앱의 모든 창을 숨긴다. 상태 막대는 남아 있어야 한다.
        let overlay = OverlayController()
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings())
        defer {
            NSApp.unhide(nil)
            overlay.apply(state: .unknown, settings: settings { $0.showStateBar = false })
        }
        let panel = try #require(overlay.panels.values.first)
        #expect(!panel.canHide)
        NSApp.hide(nil)
        #expect(panel.isVisible)
    }

    @Test func flashDoesNothingWhenBarIsHidden() {
        let overlay = OverlayController(scheduler: FakeScheduler())
        overlay.start()
        overlay.apply(state: .source(.abc), settings: settings { $0.showStateBar = false })
        overlay.flash(color: .defaultCapsLock)
        #expect(!overlay.isFlashing)
        #expect(shown(overlay).isEmpty)
    }
}

// MARK: - 입력 소스 (TIS)

@MainActor
@Suite("Input sources")
struct InputSourceControllerTests {
    @Test func currentSourceIsReadable() throws {
        let current = try #require(InputSourceController.current())
        #expect(!current.id.isEmpty)
    }

    @Test func enabledSourcesIncludeTheCurrentOneAndALatinLayout() {
        let sources = InputSourceController.enabledSources()
        #expect(!sources.isEmpty)
        #expect(sources.contains { $0.isASCIIBase })
        if let current = InputSourceController.current() {
            #expect(sources.contains { $0.id == current.id })
        }
        #expect(InputSourceController.resolvedDefaultSource(preferredID: nil) != nil)
    }

    @Test func unknownPreferredSourceFallsBackToAutomatic() {
        let automatic = InputSourceController.resolvedDefaultSource(preferredID: nil)
        #expect(InputSourceController.resolvedDefaultSource(preferredID: "does.not.exist") == automatic)
    }

    @Test func systemSwitcherReportsTheSameSourceAsTIS() {
        #expect(SystemInputSourceSwitcher().currentSource == InputSourceController.current())
        #expect(!SystemInputSourceSwitcher().perform(.none))
    }
}

// MARK: - 번역 번들

@Suite("Localization bundle", .serialized)
struct LocalizationBundleTests {
    let resources = Bundle(path: repoRoot.appendingPathComponent("Resources").path)!

    @Test(arguments: ["fr-FR", "de-DE", "zh-Hans", "es-ES"])
    func unsupportedSystemLanguagesUseTheEnglishBundle(_ language: String) {
        defer { Localization.apply(.system) }
        Localization.apply(.system, in: resources, preferredLanguages: [language])
        #expect(Localization.bundle?.bundleURL.lastPathComponent == "en.lproj")
        #expect(L("Show State Bar") == "Show State Bar")
        #expect(L("Current Input: %@", "ABC") == "Current Input: ABC")
    }

    @Test func systemUsesSupportedRegionalLanguageAndPreferenceOrder() {
        defer { Localization.apply(.system) }
        Localization.apply(.system, in: resources, preferredLanguages: ["fr-FR", "ko-KR", "ja-JP"])
        #expect(L("Show State Bar") == "상태 바 표시")
        Localization.apply(.system, in: resources, preferredLanguages: ["ja-JP", "ko-KR"])
        #expect(L("Show State Bar") == "状態バーを表示")
        Localization.apply(.en, in: resources, preferredLanguages: ["ko-KR"])
        #expect(L("Show State Bar") == "Show State Bar")
    }

    @Test func missingRequestedTranslationUsesEnglishInsteadOfSystemLanguage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            Localization.apply(.system)
            try? FileManager.default.removeItem(at: directory)
        }
        for language in ["en", "ko"] {
            try FileManager.default.copyItem(
                at: repoRoot.appendingPathComponent("Resources/\(language).lproj"),
                to: directory.appendingPathComponent("\(language).lproj")
            )
        }
        let partial = try #require(Bundle(url: directory))
        Localization.apply(.ja, in: partial, preferredLanguages: ["ko-KR"])
        #expect(Localization.bundle?.bundleURL.lastPathComponent == "en.lproj")
        #expect(L("Show State Bar") == "Show State Bar")
    }

    @Test func missingKeyUsesEnglishTextEvenInSupportedLanguage() {
        defer { Localization.apply(.system) }
        Localization.apply(.ko, in: resources)
        #expect(L("An untranslated message: %@", "ABC") == "An untranslated message: ABC")
    }

    @Test func appLanguageOverridesTheOSLanguage() {
        defer { Localization.apply(.system) }
        Localization.apply(.ko, in: resources)
        #expect(L("Show State Bar") == "상태 바 표시")
        #expect(L("Current Input: %@", "ABC") == "현재 입력: ABC")
        Localization.apply(.ja, in: resources)
        #expect(L("Show State Bar") == "状態バーを表示")
        Localization.apply(.en, in: resources)
        #expect(L("Show State Bar") == "Show State Bar")
    }

    @Test func missingTranslationFallsBackToTheEnglishKey() {
        defer { Localization.apply(.system) }
        Localization.apply(.ko, in: Bundle(path: NSTemporaryDirectory())!) // lproj가 없는 번들
        #expect(L("Show State Bar") == "Show State Bar")
    }
}

// MARK: - 설정 창 모델

@MainActor
private final class AvailableSourcesFixture {
    var values: [InputSourceInfo] = [.abc, .korean2Set]
}

@MainActor
final class RecordingActions: SettingsActions {
    var escapeResetStatus: FeatureStatus = .off
    var textFocusResetStatus: FeatureStatus = .off
    var windowSwitchResetStatus: FeatureStatus = .off
    var inputMethodInstallationStatus = InputMethodInstallationStatus()
    var isInputMethodOperationRunning = false
    var inputMethodRoutingStatus: FeatureStatus = .off
    var wrongLanguageStatus: FeatureStatus = .off
    var isWrongLanguageModelMissing = false
    var windowSwitchStalledApp: String?
    var isLaunchAtLoginEnabled = false
    var isSystemInputIndicatorHidden = false
    var isAutoCapitalizationOn = false
    var calls: [String] = []
    func refreshFeatureStatuses() {}
    func installInputMethod() { calls.append("installInputMethod") }
    func uninstallInputMethod() { calls.append("uninstallInputMethod") }
    func openInputSourceSettings() { calls.append("openInputSources") }
    func setInputMethodRouting(_ enabled: Bool) { calls.append("inputMethodRouting:\(enabled)") }
    func pauseInputMethodIntegration() { calls.append("pauseIntegration") }
    func setResetOnEscape(_ enabled: Bool) { calls.append("escape:\(enabled)") }
    func setResetOnTextFocusLoss(_ enabled: Bool) { calls.append("textFocus:\(enabled)") }
    func setWarnOnWrongLanguage(_ enabled: Bool) { calls.append("wrongLanguage:\(enabled)") }
    func setOnWindowSwitch(_ behavior: SwitchBehavior) { calls.append("window:\(behavior.rawValue)") }
    func openInputMonitoringSettings() { calls.append("openInputMonitoring") }
    func openAccessibilitySettings() { calls.append("openAccessibility") }
    func setLaunchAtLogin(_ enabled: Bool) { calls.append("login:\(enabled)"); isLaunchAtLoginEnabled = enabled }
    func setSystemInputIndicatorHidden(_ hidden: Bool) { calls.append("indicator:\(hidden)"); isSystemInputIndicatorHidden = hidden }
    func forgetPerAppInputs() { calls.append("forget") }
    func showLogFile() { calls.append("logs") }
}

@MainActor
@Suite("Settings model")
struct SettingsModelTests {
    @Test func settingsViewInitializationPreservesTheSelectedTab() {
        let model = SettingsModel(store: makeStore(), actions: RecordingActions()) { [.abc] }
        model.selectedTab = .inputMethod

        _ = SettingsView(model: model)

        #expect(model.selectedTab == .inputMethod)
    }

    @Test func pendingInputMethodSetupStartsIntegrationAfterManualActivationWithoutRetoggling() {
        let store = makeStore()
        store.update { $0.integrateInputMethod = true; $0.routeInputMethodPair = true }
        let sources = AvailableSourcesFixture()
        sources.values = [.abc]
        let actions = RecordingActions()
        actions.inputMethodInstallationStatus = .init(hasPayload: true, isInstalled: true)
        let model = SettingsModel(store: store, actions: actions) { sources.values }
        model.reload()
        // ADR 0069: the one next step is adding the modes in System Settings.
        #expect(model.inputMethodMenu.phase == .waitingForModes)
        #expect(model.inputMethodMenu.nextStep == .openInputSources)
        #expect(model.resolvedDefaultSource == .abc)
        model.perform(.openInputSources)
        #expect(actions.calls == ["openInputSources"])
        sources.values += [
            InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false),
            InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
        ]
        model.reload()
        #expect(model.inputMethodMenu.phase == .active)
        #expect(model.inputMethodMenu.nextStep == nil)
        #expect(model.resolvedDefaultSource?.id == InputMethodIntegration.latinID)
        #expect(store.settings.integrateInputMethod && store.settings.routeInputMethodPair)
        #expect(actions.calls == ["openInputSources"])
    }
    @Test func inputMethodSetupDelegatesToInstallerBeforeEnablingAndRefreshesStatus() {
        let store = makeStore()
        let actions = RecordingActions()
        actions.inputMethodInstallationStatus = .init(hasPayload: true, isInstalled: true, needsUpdate: true)
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        model.reload()
        #expect(model.inputMethodInstallationStatus.needsUpdate)
        #expect(model.inputMethodMenu.nextStep == .install(.update))
        model.perform(.install(.update))
        #expect(!store.settings.integrateInputMethod)
        model.uninstallInputMethod()
        #expect(actions.calls == ["installInputMethod", "uninstallInputMethod"])
        actions.isInputMethodOperationRunning = true
        actions.inputMethodInstallationStatus = .init(hasPayload: true)
        model.reload()
        #expect(model.inputMethodOperationRunning)
        #expect(!model.inputMethodInstallationStatus.isInstalled)
    }

    @Test func inputMethodIntegrationShowsEffectiveDefaultButPreservesPreferenceAndRecoveryUsesActions() {
        let hangul = InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false)
        let latin = InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
        let sources = AvailableSourcesFixture()
        sources.values = [.abc, hangul, latin]
        let store = makeStore()
        store.update { $0.defaultSourceID = InputMethodIntegration.abcID }
        let actions = RecordingActions()
        actions.inputMethodRoutingStatus = .needsPermission
        let model = SettingsModel(store: store, actions: actions) { sources.values }
        model.reload()
        model.binding(\.integrateInputMethod).wrappedValue = true
        #expect(model.resolvedDefaultSource == latin)
        #expect(model.automaticDefaultName == latin.displayName)
        #expect(model.defaultSourceBinding.wrappedValue == InputMethodIntegration.abcID)
        #expect(InputMethodIntegration.isAvailable(in: model.sources))
        model.inputMethodRoutingBinding.wrappedValue = true
        #expect(actions.calls == ["inputMethodRouting:true"])
        #expect(model.inputMethodRoutingStatus == .needsPermission)
        model.pauseInputMethodIntegration()
        #expect(actions.calls.last == "pauseIntegration")
        sources.values = [.abc, latin]
        model.reload()
        #expect(!InputMethodIntegration.isAvailable(in: model.sources))
        #expect(model.resolvedDefaultSource == .abc)
        #expect(store.settings.defaultSourceID == InputMethodIntegration.abcID)
    }

    @Test(arguments: [[], [InputSourceInfo.korean2Set, .hiragana]])
    func noDefaultSourceShowsNoticeInsteadOfInventingABC(_ sources: [InputSourceInfo]) {
        let model = SettingsModel(store: makeStore(), actions: RecordingActions()) { sources }
        model.reload()
        #expect(model.resolvedDefaultSource == nil)
        // 별도 번역 번들 테스트가 언어를 바꿔도 안전하게, 실제로 없는 ABC를 표시하지 않는지 확인한다.
        #expect(!model.automaticDefaultName.isEmpty && model.automaticDefaultName != "ABC")
        #expect(!model.resolvedDefaultName.isEmpty && model.resolvedDefaultName != "ABC")
        #expect(model.defaultSourceNotice != nil)
    }

    @Test func removedPreferenceIsVisibleAndRecoversWhenSourceReturns() {
        let store = makeStore()
        store.update { $0.defaultSourceID = InputSourceInfo.hiragana.id }
        let sources = AvailableSourcesFixture()
        let model = SettingsModel(store: store, actions: RecordingActions()) { sources.values }
        model.reload()
        #expect(model.unavailableDefaultSourceID == InputSourceInfo.hiragana.id)
        #expect(model.defaultSourceBinding.wrappedValue == InputSourceInfo.hiragana.id)
        #expect(model.resolvedDefaultSource == .abc)
        #expect(model.defaultSourceNotice != nil)
        sources.values.append(.hiragana)
        model.reload()
        #expect(model.unavailableDefaultSourceID == nil)
        #expect(model.resolvedDefaultSource == .hiragana)
        #expect(model.defaultSourceNotice == nil)
    }

    @Test func explicitNonLatinDefaultWorksWithoutLatinLayout() {
        let store = makeStore()
        store.update { $0.defaultSourceID = InputSourceInfo.hiragana.id }
        let model = SettingsModel(store: store, actions: RecordingActions()) { [.hiragana] }
        model.reload()
        #expect(model.resolvedDefaultSource == .hiragana)
        #expect(model.defaultSourceNotice == nil)
    }

    private func make() -> (SettingsModel, SettingsStore, RecordingActions) {
        let store = makeStore()
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { [.abc, .korean2Set, .hiragana] }
        model.reload()
        return (model, store, actions)
    }

    @Test func wrongLanguageOptionNeedsKoreanAndQWERTY() {
        let sources = AvailableSourcesFixture()
        let store = makeStore()
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { sources.values }
        model.reload()
        #expect(model.showsWrongLanguageOption)              // ABC + 두벌식
        sources.values = [.abc, .hiragana]
        model.reload()
        #expect(!model.showsWrongLanguageOption)
        store.update { $0.warnOnWrongLanguage = true }       // 켜 둔 채 두벌식을 지웠으면 끌 수 있게 보인다
        #expect(model.showsWrongLanguageOption)
        // 켜고 끄는 것은 권한 안내를 위해 actions를 거친다
        model.wrongLanguageBinding.wrappedValue = false
        #expect(actions.calls.last == "wrongLanguage:false")
    }

    @Test func missingModelIsShownInSettings() {
        let actions = RecordingActions()
        actions.isWrongLanguageModelMissing = true
        let model = SettingsModel(store: makeStore(), actions: actions) { [.abc, .korean2Set] }
        model.reload()
        #expect(model.wrongLanguageModelMissing)
    }

    @Test func wrongLanguageMessageOptionAndInvisibleWarning() {
        let store = makeStore()
        let model = SettingsModel(store: store, actions: RecordingActions()) { [.abc, .korean2Set] }
        model.reload()
        store.update { $0.warnOnWrongLanguage = true }
        #expect(!model.wrongLanguageWarningIsInvisible)
        model.binding(\.wrongLanguageShowsMessage).wrappedValue = false   // 막대 깜빡임만
        #expect(!store.settings.wrongLanguageShowsMessage)
        #expect(!model.wrongLanguageWarningIsInvisible)
        store.update { $0.showStateBar = false }                           // 막대도 숨기면 아무 데도 안 보인다
        #expect(model.wrongLanguageWarningIsInvisible)
    }

    @Test func reloadUsesInjectedSources() {
        let (model, _, _) = make()
        #expect(model.sources.map(\.id) == [InputSourceInfo.abc, .korean2Set, .hiragana].map(\.id))
        #expect(model.automaticDefaultName == "ABC")
    }

    @Test func bindingsWriteThroughToTheStore() {
        let (model, store, _) = make()
        model.binding(\.barHeight).wrappedValue = 8
        model.binding(\.barPosition).wrappedValue = .top
        #expect(store.settings.barHeight == 8)
        #expect(store.settings.barPosition == .top)
        #expect(model.settings.barHeight == 8) // 저장소 변경이 모델로 다시 반영된다
    }

    @Test func defaultSourceBindingMapsEmptyToAutomatic() {
        let (model, store, _) = make()
        model.defaultSourceBinding.wrappedValue = InputSourceInfo.korean2Set.id
        #expect(store.settings.defaultSourceID == InputSourceInfo.korean2Set.id)
        #expect(model.resolvedDefaultName == "2-Set Korean")
        model.defaultSourceBinding.wrappedValue = ""
        #expect(store.settings.defaultSourceID == nil)
    }

    @Test func colorBindingStoresOverrideAndResetClearsIt() {
        let (model, store, _) = make()
        model.colorBinding(.source(.hiragana)).wrappedValue = Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(store.settings.sourceColors[InputSourceInfo.hiragana.id]?.hexString == "#FF0000")
        #expect(model.isCustomized(.hiragana))
        model.resetColor(.hiragana)
        #expect(!model.isCustomized(.hiragana))

        model.colorBinding(.capsLock).wrappedValue = Color(nsColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        #expect(store.settings.capsLockColor.hexString == "#0000FF")
        model.resetAllColors()
        #expect(store.settings.capsLockColor == .defaultCapsLock)
    }

    @Test func stalledWindowDetectionShowsInSettings() {
        let store = makeStore()
        let actions = RecordingActions()
        actions.windowSwitchStalledApp = "Ghostty"
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        model.reload()
        #expect(model.windowSwitchStalledApp == nil) // 창 옵션이 동작 중이 아니면 보이지 않는다
        actions.windowSwitchResetStatus = .active
        model.reload()
        #expect(model.windowSwitchStalledApp == "Ghostty")
    }

    @Test func sourceIDsAreShownOnlyToTellSameNamesApart() {
        let store = makeStore()
        let twin = InputSourceInfo(id: "com.example.ABC", localizedName: "ABC", languages: ["en"], isASCIICapable: true)
        let model = SettingsModel(store: store, actions: RecordingActions()) { [.abc, .korean2Set, twin] }
        model.reload()
        #expect(model.hasDuplicateName(.abc))
        #expect(model.hasDuplicateName(twin))
        #expect(!model.hasDuplicateName(.korean2Set))
    }

    @Test func permissionTogglesGoThroughActions() {
        let (model, _, actions) = make()
        model.escapeBinding.wrappedValue = true
        model.textFocusBinding.wrappedValue = true
        model.launchAtLoginBinding.wrappedValue = true
        model.openInputMonitoring()
        model.forgetPerAppInputs()
        #expect(actions.calls == ["escape:true", "textFocus:true", "login:true", "openInputMonitoring", "forget"])
        #expect(model.launchAtLogin)
    }

    @Test func systemIndicatorToggleReflectsTheMacOSSetting() {
        // KeyHue 설정에 저장하지 않고 actions(macOS 설정)를 거쳐 실제 값을 다시 읽는다(ADR 0034)
        let (model, store, actions) = make()
        #expect(!model.systemIndicatorHidden)
        model.systemIndicatorBinding.wrappedValue = true
        #expect(actions.calls == ["indicator:true"])
        #expect(model.systemIndicatorHidden)
        #expect(store.settings == KeyHueSettings())

        // 터미널 등 KeyHue 밖에서 바꾼 값도 설정 창을 열 때 다시 읽는다
        actions.isSystemInputIndicatorHidden = false
        model.reload()
        #expect(!model.systemIndicatorHidden)
    }
}

// MARK: - macOS 입력 소스 표시 (ADR 0034)

@MainActor
@Suite("System input indicator")
struct SystemInputIndicatorTests {
    /// 실제 전역 설정 대신 임시 경로의 도메인에 쓴다(~/Library/Preferences에 파일을 남기지 않는다, TestDefaults 참고).
    private func withDomain(_ body: (SystemInputIndicator, CFString) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueTests-indicator-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file.appendingPathExtension("plist")) }
        let domain = file.path as CFString
        body(SystemInputIndicator(domain: domain), domain)
        CFPreferencesSetValue(SystemInputIndicator.key as CFString, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func rawValue(_ domain: CFString) -> CFPropertyList? {
        CFPreferencesCopyValue(SystemInputIndicator.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    @Test func usesTheGlobalMacOSKey() {
        #expect(SystemInputIndicator.key == "TSMLanguageIndicatorEnabled")
    }

    @Test func shownByDefault() {
        withDomain { indicator, _ in
            #expect(!indicator.isHidden)
        }
    }

    @Test func hidingWritesFalseAndShowingRestoresTheMacOSDefault() {
        withDomain { indicator, domain in
            indicator.setHidden(true)
            #expect(indicator.isHidden)
            #expect((rawValue(domain) as? NSNumber)?.boolValue == false)

            // 다시 표시하면 true를 쓰지 않고 키를 지워 macOS 기본값을 따르게 한다
            indicator.setHidden(false)
            #expect(!indicator.isHidden)
            #expect(rawValue(domain) == nil)
        }
    }

    @Test func readsValuesWrittenWithDefaults() {
        // `defaults write -g TSMLanguageIndicatorEnabled 0`처럼 정수로 써도 숨김으로 읽는다
        withDomain { indicator, domain in
            CFPreferencesSetValue(SystemInputIndicator.key as CFString, 0 as NSNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            #expect(indicator.isHidden)
            CFPreferencesSetValue(SystemInputIndicator.key as CFString, kCFBooleanTrue, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            #expect(!indicator.isHidden)
        }
    }
}

// MARK: - 앱 메뉴, 권한 화면

@MainActor
@Suite("App menu and permissions")
struct AppMenuTests {
    final class Target: NSObject {
        @objc func settings() {}
        @objc func about() {}
    }

    @Test func mainMenuHasStandardShortcuts() throws {
        let target = Target()
        let menu = MainMenu.make(target: target, showSettings: #selector(Target.settings), showAbout: #selector(Target.about))
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        func key(_ selector: Selector) -> String? { items.first { $0.action == selector }?.keyEquivalent }
        #expect(key(#selector(Target.settings)) == ",")
        #expect(key(#selector(NSApplication.terminate(_:))) == "q")
        #expect(key(#selector(NSWindow.performClose(_:))) == "w")
        #expect(key(#selector(NSText.copy(_:))) == "c")
        #expect(items.first { $0.action == #selector(Target.settings) }?.target === target)
    }

    @Test func permissionSettingsURLsPointToTheRightPanes() {
        #expect(PermissionKind.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
        #expect(PermissionKind.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
    }
}

// MARK: - 알림 전달 규칙 (ADR 0023)

@Suite("Notification delivery")
struct NotificationDeliveryRuleTests {
    /// KeyHue는 거의 항상 비활성 상태라, distributed notification을 기본 설정(모아서 늦게 전달)으로 받으면
    /// 한/영 전환이 최대 1.5초 늦게 반영된다(실측). 모든 구독은 selector API + .deliverImmediately여야 한다.
    @Test func distributedNotificationsAreDeliveredImmediately() throws {
        let sources = repoRoot.appendingPathComponent("Sources/KeyHueApp")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var subscriptions = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("DistributedNotificationCenter.default().addObserver") else { continue }
            let blocks = text.components(separatedBy: "DistributedNotificationCenter.default().addObserver").dropFirst()
            for block in blocks {
                subscriptions += 1
                let call = String(block.prefix(400))
                #expect(!call.hasPrefix("(forName:"), "\(file.lastPathComponent): 블록 API는 알림을 늦게 받을 수 있다")
                #expect(call.contains("suspensionBehavior: .deliverImmediately"), "\(file.lastPathComponent)")
            }
        }
        // InputSourceMonitor는 center 변수를 쓰므로 따로 확인
        let monitor = try String(contentsOf: sources.appendingPathComponent("Monitors/InputSourceMonitor.swift"), encoding: .utf8)
        #expect(monitor.contains("suspensionBehavior: .deliverImmediately"))
        #expect(!monitor.contains("addObserver(forName:"))
        #expect(subscriptions >= 1)
    }
}

// MARK: - 전환 HUD (ADR 0024)

@MainActor
@Suite("Chameleon HUD", .serialized)
struct HUDTests {
    /// 왼쪽 절반은 불투명, 오른쪽 절반은 투명한 마스크.
    private func halfMask() -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
            return true
        }
    }

    /// 색 공간을 sRGB로 못 박은 비트맵에 그려서 읽는다(cgImage(forProposedRect:)는 색 공간 태그가 없어 값이 틀어진다).
    private func pixel(_ image: NSImage, x: Int, y: Int) -> NSColor? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: x, y: 19 - y)?.usingColorSpace(.sRGB)
    }

    @Test func tintPaintsOnlyTheSilhouette() throws {
        let color = RGBAColor(hex: "#34C759")!
        let tinted = ChameleonImage.tinted(halfMask(), color: color)
        let inside = try #require(pixel(tinted, x: 5, y: 10))
        #expect(abs(inside.greenComponent - color.green) < 0.04) // 색 관리 반올림 오차(약 6/255) 허용
        #expect(abs(inside.redComponent - color.red) < 0.04)
        let outside = try #require(pixel(tinted, x: 15, y: 10))
        #expect(outside.alphaComponent < 0.01)
    }

    private var visibleFor: TimeInterval { HUDController.holdDuration }

    @Test func hudStaysWhenKeyHueIsHidden() {
        let hud = HUDController(mask: halfMask(), scheduler: FakeScheduler())
        hud.show(color: RGBAColor(hex: "#FF9500")!, on: NSScreen.main)
        defer {
            NSApp.unhide(nil)
            hud.hideNow()
        }
        NSApp.hide(nil)
        #expect(hud.isPanelVisible)
    }

    @Test func showsTintedChameleonThenHides() throws {
        let clock = FakeScheduler()
        let hud = HUDController(mask: halfMask(), scheduler: clock)
        hud.show(color: RGBAColor(hex: "#FF9500")!, on: NSScreen.main)
        #expect(hud.isShowing)
        let image = try #require(hud.image)
        let inside = try #require(pixel(image, x: 5, y: 10))
        #expect(abs(inside.redComponent - 1) < 0.04)

        clock.advance(by: visibleFor - 0.01)
        #expect(hud.isShowing)
        clock.advance(by: 0.01)
        #expect(!hud.isShowing)
    }

    @Test func diagnosticsSayWhetherAndWhereItShows() {
        let hud = HUDController(mask: halfMask(), scheduler: FakeScheduler())
        #expect(hud.diagnostics == "hidden")
        hud.show(color: RGBAColor(hex: "#FF9500")!, on: NSScreen.main)
        #expect(hud.diagnostics.hasPrefix("shown@"))
        hud.hideNow()
        #expect(hud.diagnostics == "hidden")
    }

    @Test func rapidSwitchesKeepItVisible() {
        let clock = FakeScheduler()
        let hud = HUDController(mask: halfMask(), scheduler: clock)
        hud.show(color: RGBAColor(hex: "#0A84FF")!, on: NSScreen.main)
        clock.advance(by: HUDController.holdDuration - 0.05)
        hud.show(color: RGBAColor(hex: "#34C759")!, on: NSScreen.main) // 사라지기 전에 다시 전환(유지 시간만 다시)
        clock.advance(by: HUDController.holdDuration - 0.01) // 첫 번째 숨김 예약 시각도 지났지만 무시돼야 한다
        #expect(hud.isShowing)
        clock.advance(by: 0.01)
        #expect(!hud.isShowing)
    }

    @Test func appearsInstantlyAndLeavesQuickly() {
        // ADR 0032: 전환하는 순간 바로 보이고(서서히 나타나면 전환이 늦게 느껴진다), 빠르게 사라진다. 전체도 짧게.
        let clock = FakeScheduler()
        let hud = HUDController(mask: halfMask(), scheduler: clock)
        hud.show(color: RGBAColor(hex: "#FF9500")!, on: NSScreen.main)
        #expect(hud.isFullyVisible) // 시간이 전혀 흐르지 않아도 완전히 보인다
        #expect(HUDController.fadeOutDuration <= 0.06)
        #expect(HUDController.holdDuration + HUDController.fadeOutDuration <= 0.35)
    }

    @Test func switchingAgainWhileFadingOutShowsItFullyRightAway() {
        let clock = FakeScheduler()
        let hud = HUDController(mask: halfMask(), scheduler: clock)
        hud.show(color: RGBAColor(hex: "#0A84FF")!, on: NSScreen.main)
        clock.advance(by: HUDController.holdDuration) // 사라지기 시작
        #expect(!hud.isShowing)
        hud.show(color: RGBAColor(hex: "#34C759")!, on: NSScreen.main)
        #expect(hud.isFullyVisible)
    }

    /// ADR 0063: 넘겨받은 화면의 가운데 아래에 놓는다(모니터마다).
    @Test func hudIsPlacedOnTheGivenScreen() {
        let hud = HUDController(mask: halfMask(), scheduler: FakeScheduler())
        defer { hud.hideNow() }
        for screen in NSScreen.screens {
            hud.show(color: RGBAColor(hex: "#FF9500")!, on: screen)
            #expect(hud.panelFrame == ScreenGeometry.hudFrame(visibleFrame: screen.visibleFrame, size: HUDController.size, bottomOffset: HUDController.bottomOffset))
            #expect(screen.frame.contains(hud.panelFrame))
        }
    }

    /// ADR 0063: 표시 순간 키보드 포커스가 있는 화면이 앱 전환 때 구해 둔 화면보다 우선한다.
    @Test func focusedScreenIsPreferred() {
        let screens = NSScreen.screens
        guard let first = screens.first, let last = screens.last else { return }
        #expect(ActiveScreenLocator.focusedScreen(focused: last, activeAppScreen: first) == last)
        #expect(ActiveScreenLocator.focusedScreen(focused: nil, activeAppScreen: last) == last)
        #expect(ActiveScreenLocator.focusedScreen(focused: nil, activeAppScreen: nil) == first)
    }

    /// ADR 0063: 같은 앱 안에서 다른 모니터의 창으로 포커스가 옮겨 가면 macOS가 보내는 알림을 전달한다.
    @Test func activeDisplayChangeIsReported() {
        let monitor = AppFocusMonitor()
        var changes = 0
        monitor.onActiveDisplayChanged = { changes += 1 }
        monitor.start()
        NSWorkspace.shared.notificationCenter.post(name: AppFocusMonitor.activeDisplayDidChange, object: nil)
        #expect(changes == 1)
        monitor.stop()
        NSWorkspace.shared.notificationCenter.post(name: AppFocusMonitor.activeDisplayDidChange, object: nil)
        #expect(changes == 1)
    }

    @Test func typingHidesItImmediately() {
        let clock = FakeScheduler()
        let hud = HUDController(mask: halfMask(), scheduler: clock)
        hud.show(color: RGBAColor(hex: "#34C759")!, on: NSScreen.main)
        #expect(hud.isShowing)
        hud.hideNow()
        #expect(!hud.isShowing)
        hud.hideNow() // 떠 있지 않을 때는 아무것도 하지 않는다
        #expect(!hud.isShowing)
    }

    @Test func staleHideDoesNotHideANewHUD() {
        let clock = FakeScheduler()
        let hud = HUDController(mask: halfMask(), scheduler: clock)
        hud.show(color: RGBAColor(hex: "#34C759")!, on: NSScreen.main)
        hud.hideNow()
        clock.advance(by: 0.1)
        hud.show(color: RGBAColor(hex: "#0A84FF")!, on: NSScreen.main) // 바로 다시 전환
        clock.advance(by: visibleFor - 0.01) // 첫 번째 숨김 예약 시각이 지나도
        #expect(hud.isShowing)
        clock.advance(by: 0.2)
        #expect(!hud.isShowing)
    }
}

// MARK: - 창 전환 (ADR 0027)

@MainActor
@Suite("Window switching")
struct WindowSwitchingAppTests {
    @Test func windowIdentityUsesCFEqual() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(AXWindowID(element: AXUIElementCreateApplication(pid)) == AXWindowID(element: AXUIElementCreateApplication(pid)))
        #expect(AXWindowID(element: AXUIElementCreateApplication(pid)) != AXWindowID(element: AXUIElementCreateApplication(1)))
    }

    @Test func listensForMainWindowChanges() {
        // 탭 전환은 "포커스 창 변경"이 오지 않고 "메인 창 변경"만 온다(실측)
        let names = AccessibilityFocusMonitor.notifications(for: AccessibilityUse(textFocus: false, windowSwitches: true))
        #expect(names.contains(kAXMainWindowChangedNotification))
        #expect(!names.contains(kAXFocusedWindowChangedNotification))
    }

    // MARK: 성능: 필요한 것만 관찰하고, 멈춘 앱을 오래 기다리지 않는다

    @Test func subscribesOnlyToWhatTheEnabledOptionsNeed() {
        // 창 옵션만 켜면 자주 오는 포커스 변경 알림은 구독하지 않는다(알림마다 AX 조회 3번이 생긴다)
        let windowsOnly = AccessibilityUse(textFocus: false, windowSwitches: true)
        #expect(AccessibilityFocusMonitor.notifications(for: windowsOnly) == [kAXMainWindowChangedNotification])
        #expect(AccessibilityFocusMonitor.initialAttributes(for: windowsOnly) == [kAXMainWindowAttribute])

        let textOnly = AccessibilityUse(textFocus: true, windowSwitches: false)
        #expect(AccessibilityFocusMonitor.notifications(for: textOnly) == [kAXFocusedUIElementChangedNotification])
        #expect(AccessibilityFocusMonitor.initialAttributes(for: textOnly) == [kAXFocusedUIElementAttribute])

        let both = AccessibilityUse(textFocus: true, windowSwitches: true)
        #expect(Set(AccessibilityFocusMonitor.notifications(for: both)) == [kAXFocusedUIElementChangedNotification, kAXMainWindowChangedNotification])

        let none = AccessibilityUse(textFocus: false, windowSwitches: false)
        #expect(AccessibilityFocusMonitor.notifications(for: none).isEmpty)
        #expect(AccessibilityFocusMonitor.initialAttributes(for: none).isEmpty)
    }

    @Test func notificationRegistrationErrorsAreClassifiedInsteadOfSilentlyIgnored() {
        #expect(AccessibilityFocusMonitor.registrationDisposition(for: .success) == .added)
        #expect(AccessibilityFocusMonitor.registrationDisposition(for: .cannotComplete) == .retry)
        #expect(AccessibilityFocusMonitor.registrationDisposition(for: .notificationUnsupported) == .unsupported)
        #expect(AccessibilityFocusMonitor.registrationDisposition(for: .illegalArgument) == .failed)
    }

    @Test func oneUnregisteredNotificationKeepsTheOthers() {
        typealias Monitor = AccessibilityFocusMonitor
        // 실행 중인 앱: 전부 되돌리고 다시 시도한다
        #expect(Monitor.registrationOutcome([.added, .retry]) == .retry)
        // 하나만 지원하지 않거나 실패하면 나머지로 붙는다
        #expect(Monitor.registrationOutcome([.unsupported, .added]) == .attach)
        #expect(Monitor.registrationOutcome([.failed, .added]) == .attach)
        // 하나도 못 붙였을 때: 지원하지 않는 알림뿐이면 그만두고, 아니면 다시 시도한다
        #expect(Monitor.registrationOutcome([.unsupported, .unsupported]) == .unsupported)
        #expect(Monitor.registrationOutcome([.unsupported, .failed]) == .retry)
    }

    @Test func nothingToObserveMeansDetached() {
        let monitor = AccessibilityFocusMonitor()
        monitor.attach(to: ProcessInfo.processInfo.processIdentifier, for: AccessibilityUse(textFocus: false, windowSwitches: false))
        #expect(!monitor.isAttached)
        #expect(monitor.currentWindow == nil)
    }

    @Test func accessibilityRequestsGiveUpQuickly() {
        // 멈춘 앱(무지개 공)에 AX를 물으면 요청마다 기본 약 1.5초(실측)를 기다려 메인 스레드가 막힌다. 짧게 끊는다
        #expect(AccessibilityFocusMonitor.messagingTimeout > 0)
        #expect(AccessibilityFocusMonitor.messagingTimeout <= 0.5)
        #expect(AccessibilityFocusMonitor.applyMessagingTimeout() == .success)
    }

    @Test func settingsToggleGoesThroughActions() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        // 창 옵션은 권한 안내가 필요하므로 설정을 직접 바꾸지 않고 actions를 거친다
        model.windowSwitchBinding.wrappedValue = .restoreLast
        #expect(actions.calls == ["window:restoreLast"])
        #expect(store.settings.onWindowSwitch == .keep)
    }

    // MARK: 창별 기억 (ADR 0028)

    @Test func windowIdentityHashMatchesEquality() {
        // 창별 기억은 사전 키로 쓰므로 CFEqual이 같으면 해시도 같아야 한다
        let pid = ProcessInfo.processInfo.processIdentifier
        let a = AXWindowID(element: AXUIElementCreateApplication(pid))
        let b = AXWindowID(element: AXUIElementCreateApplication(pid))
        #expect(a.hashValue == b.hashValue)
        #expect(Set([AnyHashable(a), AnyHashable(b)]).count == 1)
        var memory = WindowInputMemory<AnyHashable>()
        memory.record(sourceID: InputSourceInfo.korean2Set.id, for: AnyHashable(a))
        #expect(memory.source(for: AnyHashable(b)) == InputSourceInfo.korean2Set.id)
    }

    @Test func appSwitchPickerWritesDirectly() {
        // 앱 옵션은 권한이 필요 없어 바로 저장한다
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = RecordingActions()
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        model.binding(\.onAppSwitch).wrappedValue = .restoreLast
        #expect(store.settings.onAppSwitch == .restoreLast)
        #expect(actions.calls.isEmpty)
    }

    @Test func settingsShowWindowPermissionState() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = RecordingActions()
        actions.windowSwitchResetStatus = .needsPermission
        let model = SettingsModel(store: store, actions: actions) { [.abc] }
        model.reload()
        #expect(model.windowSwitchStatus == .needsPermission)
    }
}

@MainActor
@Suite("Wrong language monitor")
struct WrongLanguageMonitorTests {
    static let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Mistype/hangul-syllables.tsv")

    /// 키 코드로 친다(공백은 스페이스 키).
    private func type(_ text: String, sourceID: String, into monitor: WrongLanguageMonitor) {
        let codes: [Character: Int64] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49
        ]
        for char in text {
            let key = KeyboardMonitor.KeyDown(
                keyCode: codes[Character(char.lowercased())]!, isAutoRepeat: false,
                shift: char.isUppercase, otherModifiers: false, capsLock: false
            )
            monitor.key(key, sourceID: sourceID)
        }
    }

    @Test func bundledModelLoadsAndWarnsInBothDirections() async throws {
        // 접두사 없이: 단어 끝(공백)에서만 판정한다(ADR 0041)
        let monitor = WrongLanguageMonitor(
            modelURL: Self.modelURL, lexicon: { WordListLexicon(["hello", "world"]) }, prefixWords: { [] }
        )
        await monitor.prepare()
        #expect(monitor.isReady)
        monitor.setEnabled(true)
        var verdicts: [MistypeVerdict] = []
        monitor.onWarning = { verdict, _ in verdicts.append(verdict) }

        type("dkssudgktpdy ", sourceID: InputSourceInfo.abc.id, into: monitor)
        #expect(verdicts == [.meantHangul("안녕하세요")])
        type("hello ", sourceID: InputSourceInfo.korean2Set.id, into: monitor)
        #expect(verdicts.last == .meantLatin("hello"))
        type("hello world ", sourceID: InputSourceInfo.abc.id, into: monitor)
        #expect(verdicts.count == 2)
        // 지원하지 않는 입력 소스에서는 보지 않는다
        type("dkssud ", sourceID: "com.apple.keylayout.German", into: monitor)
        #expect(verdicts.count == 2)
    }

    @Test func warnsWhileTypingOncePerWord() async {
        // 영어 접두사가 있으면 치는 중에 알리고(ADR 0042), 같은 단어에서는 다시 알리지 않는다
        let monitor = WrongLanguageMonitor(
            modelURL: Self.modelURL, lexicon: { WordListLexicon(["hello", "world"]) }, prefixWords: { ["hello", "help", "world"] }
        )
        await monitor.prepare()
        monitor.setEnabled(true)
        var warnings: [(MistypeVerdict, Bool)] = []
        monitor.onWarning = { warnings.append(($0, $1)) }

        type("dks", sourceID: InputSourceInfo.abc.id, into: monitor)
        #expect(warnings.count == 1)
        #expect(warnings.first?.0 == .meantHangul("안"))
        #expect(warnings.first?.1 == true)
        type("sudgktpdy ", sourceID: InputSourceInfo.abc.id, into: monitor)
        #expect(warnings.count == 1)                       // 같은 단어: 단어 끝에서도 다시 알리지 않는다

        type("he", sourceID: InputSourceInfo.korean2Set.id, into: monitor)  // ㅗㄷ: ㅗ가 낱자로 확정
        #expect(warnings.last?.0 == .meantLatin("he"))
        type("llo world ", sourceID: InputSourceInfo.korean2Set.id, into: monitor)
        #expect(warnings.count == 3)                       // world는 새 단어(ㅈ개ㅣㅇ)
    }

    @Test func prefixWordsIncludeInstalledCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["dirname", "git-lfs", "python3"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }
        let words = EnglishPrefixIndex.loadWords(wordLists: ["/nonexistent"], commandDirectories: [directory.path, "/nonexistent"])
        #expect(words == ["dirname"]) // 영문자로만 된 이름만
    }

    @Test func disabledMonitorIgnoresKeys() async {
        let monitor = WrongLanguageMonitor(modelURL: Self.modelURL, lexicon: { WordListLexicon([]) })
        await monitor.prepare()
        var warned = false
        monitor.onWarning = { _, _ in warned = true }
        type("dkssudgktpdy ", sourceID: InputSourceInfo.abc.id, into: monitor)
        #expect(!warned)
    }

    @Test func missingModelIsReported() async {
        let monitor = WrongLanguageMonitor(modelURL: nil, lexicon: { WordListLexicon([]) })
        await monitor.prepare()
        #expect(monitor.isModelMissing)
        #expect(!monitor.isReady)
    }

    @Test func toastShowsTheWordThenHides() {
        let clock = FakeScheduler()
        let toast = WrongLanguageToast(mask: NSImage(size: NSSize(width: 20, height: 20)), scheduler: clock)
        toast.show(word: "안녕하세요", sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.isShowing)
        #expect(toast.word == "안녕하세요?")
        #expect(!toast.caption.isEmpty && toast.caption.contains("2-Set Korean"))
        #expect(toast.frame.width > 100) // 내용에 맞춘 크기

        // 계속 타이핑해도 읽을 시간 동안은 남아 있다
        clock.advance(by: WrongLanguageToast.holdDuration - 0.1)
        #expect(toast.isShowing)
        clock.advance(by: 0.2)
        #expect(!toast.isShowing)
    }

    @Test func toastTruncatesLongWords() {
        let toast = WrongLanguageToast(mask: NSImage(size: NSSize(width: 20, height: 20)), scheduler: FakeScheduler())
        toast.show(word: String(repeating: "가", count: 40), sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.word.count == 24 + 2) // 24자 + "…?"
    }

    @Test func toastHidesAtOnceWhenTheUserReacts() {
        // 경고를 보고 입력 소스를 바꾸면 바로 숨는다(같은 자리에 뜨는 전환 HUD와 겹치지 않게)
        let clock = FakeScheduler()
        let toast = WrongLanguageToast(mask: NSImage(size: NSSize(width: 20, height: 20)), scheduler: clock)
        toast.show(word: "안…", sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        toast.hideNow()
        #expect(!toast.isShowing)
        #expect(!toast.isPanelVisible)
        clock.advance(by: 2) // 남아 있던 숨김 예약이 아무 일도 하지 않는다
        toast.show(word: "he…", sourceName: "ABC", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.isPanelVisible)
        toast.hideNow()
    }

    @Test func toastStaysWhenKeyHueIsHidden() {
        let toast = WrongLanguageToast(mask: NSImage(size: NSSize(width: 20, height: 20)), scheduler: FakeScheduler())
        toast.show(word: "안녕", sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        defer { NSApp.unhide(nil) }
        NSApp.hide(nil)
        #expect(toast.isPanelVisible)
    }

    @Test func logNeverContainsTheWord() {
        #expect(WrongLanguageMonitor.logDescription(.meantHangul("안녕")) == "meant hangul")
        #expect(WrongLanguageMonitor.logDescription(.meantLatin("hello")) == "meant latin")
    }

    @Test func systemLexiconRejectsRomanNumeralNoise() {
        let lexicon = SystemEnglishLexicon()
        #expect(lexicon.contains("hello"))
        #expect(!lexicon.contains("vlxl")) // 피티: NSSpellChecker는 로마 숫자로 보고 받아 준다
        #expect(lexicon.contains("did"))   // 로마 숫자 글자로만 됐지만 실제 단어
    }
}


@MainActor
@Suite("Accessibility attach decision")
struct AccessibilityAttachDecisionTests {
    typealias Target = AccessibilityFocusMonitor.AttachTarget
    let windows = AccessibilityUse(textFocus: false, windowSwitches: true)

    @Test func stalledAppIsNotRetriedOnEveryMenuOpen() {
        // 붙기를 포기한 앱: 메뉴·설정 창을 열 때 다시 붙으면 "응답 없는 앱" 안내가 지워진다(ADR 0038)
        let target = Target(pid: 42, use: windows)
        #expect(!AccessibilityFocusMonitor.needsAttach(to: target, attached: nil, pending: nil, stalledPID: 42))
    }

    @Test func anotherAppOrUseAttaches() {
        #expect(AccessibilityFocusMonitor.needsAttach(to: Target(pid: 7, use: windows), attached: nil, pending: nil, stalledPID: 42))
        let both = AccessibilityUse(textFocus: true, windowSwitches: true)
        #expect(AccessibilityFocusMonitor.needsAttach(
            to: Target(pid: 7, use: both), attached: Target(pid: 7, use: windows), pending: nil, stalledPID: nil
        ))
    }

    @Test func alreadyAttachedOrRetryingDoesNothing() {
        let target = Target(pid: 7, use: windows)
        #expect(!AccessibilityFocusMonitor.needsAttach(to: target, attached: target, pending: nil, stalledPID: nil))
        #expect(!AccessibilityFocusMonitor.needsAttach(to: target, attached: nil, pending: target, stalledPID: nil))
        #expect(AccessibilityFocusMonitor.needsAttach(to: target, attached: nil, pending: nil, stalledPID: nil))
    }
}
