import AppKit
import Foundation
import KeyHueCore
import SwiftUI
import Testing
@testable import KeyHueApp

/// 권한 안내에서 "취소"를 고르거나 시스템 변경이 실패한 것처럼 동작하는 actions.
/// 요청은 기록하지만 설정·시스템 값은 바꾸지 않는다.
@MainActor
final class AppEdgeDecliningActions: StatusBarActions {
    var escapeResetStatus: FeatureStatus = .off
    var textFocusResetStatus: FeatureStatus = .off
    var windowSwitchResetStatus: FeatureStatus = .off
    var wrongLanguageStatus: FeatureStatus = .off
    var inputMethodRoutingStatus: FeatureStatus = .off
    var inputMethodInstallationStatus = InputMethodInstallationStatus()
    var isInputMethodOperationRunning = false
    var isWrongLanguageModelMissing = false
    var windowSwitchStalledApp: String?
    var isLaunchAtLoginEnabled = false
    var isSystemInputIndicatorHidden = false
    var calls: [String] = []
    func setInputMethodEnabled(_ enabled: Bool) { calls.append("inputMethodEnabled:\(enabled)") }
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
    func setLaunchAtLogin(_ enabled: Bool) { calls.append("login:\(enabled)") }          // SMAppService 실패
    func setSystemInputIndicatorHidden(_ hidden: Bool) { calls.append("indicator:\(hidden)") } // 쓰기 실패
    func forgetPerAppInputs() { calls.append("forget") }
    func showSettings() { calls.append("settings") }
    func showUpdates() { calls.append("updates") }
    func showLogFile() { calls.append("logs") }
}

/// 설정 모델 경계 테스트용 입력 소스(테스트 인자에서 쓰므로 actor에 묶이지 않게 둔다).
enum AppEdgeSources {
    static let keyHueKorean = InputSourceInfo(id: InputMethodIntegration.hangulID, localizedName: "KeyHue Korean", languages: ["ko"], isASCIICapable: false)
    static let keyHueEnglish = InputSourceInfo(id: InputMethodIntegration.latinID, localizedName: "KeyHue English", languages: ["en"], isASCIICapable: true)
    static let dvorak = InputSourceInfo(id: "com.apple.keylayout.Dvorak", localizedName: "Dvorak", languages: ["en"], isASCIICapable: true)
    static let us = InputSourceInfo(id: "com.apple.keylayout.US", localizedName: "U.S.", languages: ["en"], isASCIICapable: true)
    static let korean3Set = InputSourceInfo(id: "com.apple.inputmethod.Korean.390Sebulshik", localizedName: "3-Set Korean", languages: ["ko"], isASCIICapable: false)

}

@MainActor
@Suite("Settings model edge cases")
struct AppEdgeSettingsModelTests {
    private func makeModel(
        _ actions: StatusBarActions, store: SettingsStore = SettingsStore(defaults: makeTestDefaults()),
        sources: [InputSourceInfo] = [.abc, .korean2Set]
    ) -> SettingsModel {
        let model = SettingsModel(
            store: store, actions: actions,
            updates: UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), scheduler: FakeScheduler()) {
                throw GitHubReleaseFetcher.Failure.invalidResponse
            }
        ) { sources }
        model.reload()
        return model
    }

    @Test func declinedPermissionPromptsLeaveEveryOptionOff() {
        // 권한 안내에서 취소하면 actions가 설정을 바꾸지 않는다. 토글은 다시 꺼진 상태로 보여야 한다.
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = AppEdgeDecliningActions()
        let model = makeModel(actions, store: store)
        model.escapeBinding.wrappedValue = true
        model.textFocusBinding.wrappedValue = true
        model.wrongLanguageBinding.wrappedValue = true
        model.windowSwitchBinding.wrappedValue = .switchToDefault
        model.inputMethodEnabledBinding.wrappedValue = true
        model.inputMethodRoutingBinding.wrappedValue = true
        #expect(actions.calls == [
            "escape:true", "textFocus:true", "wrongLanguage:true", "window:switchToDefault",
            "inputMethodEnabled:true", "inputMethodRouting:true"
        ])
        #expect(store.settings == KeyHueSettings())
        #expect(!model.escapeBinding.wrappedValue)
        #expect(!model.textFocusBinding.wrappedValue)
        #expect(!model.wrongLanguageBinding.wrappedValue)
        #expect(model.windowSwitchBinding.wrappedValue == .keep)
        #expect(!model.inputMethodEnabledBinding.wrappedValue)
        #expect(!model.inputMethodRoutingBinding.wrappedValue)
    }

    @Test func failedSystemChangesShowTheRealValue() {
        // 로그인 시 실행·macOS 표시 설정을 바꾸지 못했으면, 누른 값이 아니라 실제 값을 다시 읽어 보여 준다.
        let actions = AppEdgeDecliningActions()
        let model = makeModel(actions)
        model.launchAtLoginBinding.wrappedValue = true
        model.systemIndicatorBinding.wrappedValue = true
        #expect(actions.calls == ["login:true", "indicator:true"])
        #expect(!model.launchAtLogin)
        #expect(!model.launchAtLoginBinding.wrappedValue)
        #expect(!model.systemIndicatorHidden)
        #expect(!model.systemIndicatorBinding.wrappedValue)
    }

    @Test func statusesRefreshWhenSettingsChangeWithoutReload() {
        // 권한 안내를 거쳐 설정이 바뀌면(저장소 변경) 창을 다시 열지 않아도 "권한 필요" 안내가 바로 보인다.
        let store = SettingsStore(defaults: makeTestDefaults())
        let actions = RecordingActions()
        let model = makeModel(actions, store: store)
        #expect(model.escapeStatus == .off)
        actions.escapeResetStatus = .needsPermission
        actions.wrongLanguageStatus = .needsPermission
        actions.inputMethodRoutingStatus = .active
        store.update { $0.resetOnEscape = true }
        #expect(model.escapeStatus == .needsPermission)
        #expect(model.wrongLanguageStatus == .needsPermission)
        #expect(model.inputMethodRoutingStatus == .active)
    }

    @Test(arguments: [FeatureStatus.off, .needsPermission])
    func stalledAppIsShownOnlyWhileTheWindowOptionWorks(_ status: FeatureStatus) {
        let actions = RecordingActions()
        actions.windowSwitchStalledApp = "Ghostty"
        actions.windowSwitchResetStatus = status
        let model = makeModel(actions)
        #expect(model.windowSwitchStatus == status)
        #expect(model.windowSwitchStalledApp == nil)
    }

    @Test func releasedActionsMakeTheModelInert() throws {
        // actions는 weak다. AppDelegate가 먼저 사라져도(종료 중) 설정 창 모델이 멈추거나 설정을 바꾸지 않는다.
        let store = SettingsStore(defaults: makeTestDefaults())
        var actions: RecordingActions? = RecordingActions()
        actions?.escapeResetStatus = .active
        actions?.isLaunchAtLoginEnabled = true
        actions?.isWrongLanguageModelMissing = true
        let model = makeModel(actions!, store: store)
        #expect(model.escapeStatus == .active)
        #expect(model.launchAtLogin)
        weak var probe = actions
        actions = nil
        #expect(probe == nil)
        model.reload()
        #expect(model.escapeStatus == .off)
        #expect(!model.launchAtLogin)
        #expect(!model.wrongLanguageModelMissing)
        model.escapeBinding.wrappedValue = true
        model.launchAtLoginBinding.wrappedValue = true
        model.windowSwitchBinding.wrappedValue = .restoreLast
        model.installInputMethod()
        model.forgetPerAppInputs()
        #expect(store.settings == KeyHueSettings())
        // 권한이 필요 없는 설정은 계속 바로 저장된다
        model.binding(\.showHUD).wrappedValue = false
        #expect(!store.settings.showHUD)
    }

    @Test(arguments: [
        ([InputSourceInfo.korean2Set, AppEdgeSources.us], true),
        ([AppEdgeSources.keyHueKorean, AppEdgeSources.keyHueEnglish], true),          // KeyHue 입력기 두 모드만 있어도 두벌식·QWERTY
        ([InputSourceInfo.korean2Set, AppEdgeSources.keyHueEnglish], true),
        ([InputSourceInfo.korean2Set, AppEdgeSources.dvorak], false),      // QWERTY가 아닌 영문 배열
        ([AppEdgeSources.korean3Set, InputSourceInfo.abc], false),          // 세벌식은 지원하지 않는다
        ([InputSourceInfo.korean2Set], false),
        ([InputSourceInfo.abc], false),
        ([], false)
    ])
    func wrongLanguageOptionVisibility(_ sources: [InputSourceInfo], _ visible: Bool) {
        let model = makeModel(RecordingActions(), sources: sources)
        #expect(model.showsWrongLanguageOption == visible)
    }

    @Test func invisibleWarningNoticeOnlyWhenTheFeatureIsOn() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(RecordingActions(), store: store)
        store.update { $0.showStateBar = false; $0.wrongLanguageShowsMessage = false }
        #expect(!model.wrongLanguageWarningIsInvisible) // 꺼 둔 기능은 안내하지 않는다
        store.update { $0.warnOnWrongLanguage = true }
        #expect(model.wrongLanguageWarningIsInvisible)
        store.update { $0.wrongLanguageShowsMessage = true }
        #expect(!model.wrongLanguageWarningIsInvisible)
    }

    @Test func removedPreferenceWithNothingLeftShowsTheNoSourceNotice() throws {
        // 고른 입력 소스도 지우고 대체할 영문 배열도 없으면 "다른 소스를 쓴다"가 아니라 "쓸 소스가 없다"를 알린다.
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.defaultSourceID = InputSourceInfo.hiragana.id }
        let model = makeModel(RecordingActions(), store: store, sources: [.korean2Set])
        #expect(model.unavailableDefaultSourceID == InputSourceInfo.hiragana.id)
        #expect(model.resolvedDefaultSource == nil)
        let notice = try #require(model.defaultSourceNotice)
        #expect(AppEdgeText.anyLanguage(
            "No default input source is available. Add an input source in System Settings › Keyboard › Input Sources. Automatic switching will keep the current input source."
        ).contains(notice))
        #expect(AppEdgeText.anyLanguage("Default Input Source").contains(model.resolvedDefaultName))
        #expect(store.settings.defaultSourceID == InputSourceInfo.hiragana.id) // 고른 값은 지우지 않는다
    }

    @Test func removedPreferenceNoticeNamesTheFallback() throws {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.defaultSourceID = InputSourceInfo.hiragana.id }
        let model = makeModel(RecordingActions(), store: store, sources: [.korean2Set, AppEdgeSources.us])
        #expect(model.resolvedDefaultSource == AppEdgeSources.us)
        let notice = try #require(model.defaultSourceNotice)
        #expect(AppEdgeText.anyLanguage("The selected input source is unavailable. Automatic switching will use %@ instead.", "U.S.").contains(notice))
    }

    @Test func unnamedSourcesShowTheirIDAndAreNotTreatedAsDuplicates() {
        let first = InputSourceInfo(id: "com.example.first", localizedName: "", languages: ["en"], isASCIICapable: true)
        let second = InputSourceInfo(id: "com.example.second", localizedName: "", languages: ["en"], isASCIICapable: true)
        let model = makeModel(RecordingActions(), sources: [first, second])
        #expect(ColorTarget.source(first).title == "com.example.first")
        #expect(!model.hasDuplicateName(first))
        #expect(!model.hasDuplicateName(second))
        // 목록에 없는 소스는 같은 이름이 하나뿐이어도 중복이 아니다
        #expect(!model.hasDuplicateName(.abc))
    }

    @Test func defaultSourceCanBePickedBeforeItIsEnabledAndRecoversLater() {
        // 아직 켜지 않은 소스 ID를 고르면(다른 Mac에서 옮긴 설정 등) 그대로 저장하고 대체 소스를 알린다.
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(RecordingActions(), store: store, sources: [.abc])
        model.defaultSourceBinding.wrappedValue = InputSourceInfo.korean2Set.id
        #expect(store.settings.defaultSourceID == InputSourceInfo.korean2Set.id)
        #expect(model.unavailableDefaultSourceID == InputSourceInfo.korean2Set.id)
        #expect(model.resolvedDefaultSource == .abc)
        #expect(model.defaultSourceBinding.wrappedValue == InputSourceInfo.korean2Set.id)
    }

    @Test func colorThatCannotBeExpressedInSRGBIsNotStored() {
        // 패턴 색처럼 sRGB 값이 없는 색은 저장하지 않는다(설정이 깨지지 않게).
        let store = SettingsStore(defaults: makeTestDefaults())
        let model = makeModel(RecordingActions(), store: store)
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))
        model.colorBinding(.source(.abc)).wrappedValue = Color(nsColor: pattern)
        model.colorBinding(.capsLock).wrappedValue = Color(nsColor: pattern)
        #expect(store.settings == KeyHueSettings())
    }
}
