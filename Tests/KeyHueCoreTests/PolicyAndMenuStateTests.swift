import Foundation
import Testing
@testable import KeyHueCore

@Suite("PermissionPolicy")
struct PermissionPolicyTests {
    @Test func status() {
        #expect(PermissionPolicy.status(isEnabled: false, isWorking: false) == .off)
        #expect(PermissionPolicy.status(isEnabled: false, isWorking: true) == .off)
        #expect(PermissionPolicy.status(isEnabled: true, isWorking: true) == .active)
        #expect(PermissionPolicy.status(isEnabled: true, isWorking: false) == .needsPermission)
    }

    @Test func noWarningForFeaturesThatAreOff() {
        #expect(PermissionPolicy.missingOnLaunch(settings: KeyHueSettings(), hasInputMonitoring: false, hasAccessibility: false) == nil)
    }

    @Test func warnsForEnabledFeatureWithoutPermission() {
        var settings = KeyHueSettings()
        settings.resetOnEscape = true
        #expect(PermissionPolicy.missingOnLaunch(settings: settings, hasInputMonitoring: false, hasAccessibility: true) == .inputMonitoring)
        #expect(PermissionPolicy.missingOnLaunch(settings: settings, hasInputMonitoring: true, hasAccessibility: false) == nil)

        settings.resetOnTextFocusLoss = true
        #expect(PermissionPolicy.missingOnLaunch(settings: settings, hasInputMonitoring: true, hasAccessibility: false) == .accessibility)
        // 둘 다 없으면 ESC를 먼저 알린다
        #expect(PermissionPolicy.missingOnLaunch(settings: settings, hasInputMonitoring: false, hasAccessibility: false) == .inputMonitoring)
    }

    @Test func activeScreenIsFollowedOnlyWhenSomethingUsesIt() {
        // 활성 화면(창 목록 조회)은 활성 모니터 표시, HUD, 한/영 경고 메시지에서만 구한다
        var settings = KeyHueSettings()
        #expect(!settings.followsActiveScreen)
        settings.warnOnWrongLanguage = true
        #expect(settings.followsActiveScreen)          // 메시지 기본 켜짐
        settings.wrongLanguageShowsMessage = false
        #expect(!settings.followsActiveScreen)         // 막대 깜빡임만이면 필요 없다
        settings.showHUD = true
        #expect(settings.followsActiveScreen)
        settings.showHUD = false
        settings.displayPolicy = .activeScreen
        #expect(settings.followsActiveScreen)
    }

    @Test func wrongLanguageWarningNeedsInputMonitoring() {
        var settings = KeyHueSettings()
        settings.warnOnWrongLanguage = true
        #expect(settings.watchesKeyboard)
        #expect(PermissionPolicy.missingOnLaunch(settings: settings, hasInputMonitoring: false, hasAccessibility: true) == .inputMonitoring)
        PermissionPolicy.disableFeature(needing: .inputMonitoring, in: &settings)
        #expect(!settings.warnOnWrongLanguage)
        #expect(!settings.watchesKeyboard)
    }

    @Test func turnOffDisablesOnlyTheAffectedFeature() {
        var settings = KeyHueSettings()
        settings.resetOnEscape = true
        settings.resetOnTextFocusLoss = true
        PermissionPolicy.disableFeature(needing: .accessibility, in: &settings)
        #expect(settings.resetOnEscape)
        #expect(!settings.resetOnTextFocusLoss)
        PermissionPolicy.disableFeature(needing: .inputMonitoring, in: &settings)
        #expect(!settings.resetOnEscape)
    }

    @Test func tccServiceNames() {
        #expect(PermissionKind.inputMonitoring.tccService == "ListenEvent")
        #expect(PermissionKind.accessibility.tccService == "Accessibility")
    }
}

@Suite("StatusMenuState")
struct StatusMenuStateTests {
    private func state(
        _ configure: (inout KeyHueSettings) -> Void = { _ in },
        sources: [InputSourceInfo] = [.abc, .korean2Set],
        escape: FeatureStatus = .off,
        textFocus: FeatureStatus = .off
    ) -> StatusMenuState {
        var settings = KeyHueSettings()
        configure(&settings)
        return StatusMenuState(settings: settings, enabledSources: sources, escape: escape, textFocus: textFocus)
    }

    @Test func defaults() {
        let s = state()
        #expect(s.showStateBar)
        #expect(s.onAppSwitch == .keep)
        #expect(s.onWindowSwitch == .keep)
        #expect(!s.showsForgetItem)
        #expect(!s.showsEscapePermissionItem)
    }

    @Test func permissionItemsAppearOnlyWhenNeeded() {
        #expect(state(escape: .needsPermission).showsEscapePermissionItem)
        #expect(!state(escape: .active).showsEscapePermissionItem)
        #expect(state(textFocus: .needsPermission).showsTextFocusPermissionItem)
        #expect(!state(textFocus: .off).showsTextFocusPermissionItem)
    }

    @Test func forgetItemFollowsMemoryOption() {
        #expect(state { $0.onAppSwitch = .restoreLast }.showsForgetItem)
    }

    @Test func defaultSourceNameUsesPickedSource() {
        #expect(state().defaultSourceName == "ABC")
        #expect(state(sources: [.korean2Set, .us]).defaultSourceName == "U.S.")
        #expect(state({ $0.defaultSourceID = InputSourceInfo.german.id }, sources: [.abc, .german]).defaultSourceName == "German")
        // 대상이 없으면 ABC가 있는 것처럼 표시하지 않는다. 앱 UI가 안내 문구를 번역한다.
        #expect(state(sources: [.korean2Set]).defaultSourceName == nil)
        #expect(state(sources: [.korean2Set]).automaticSourceName == nil)
    }

    @Test func displayNameFallsBackToID() {
        let unnamed = InputSourceInfo(id: "x.y", localizedName: "", languages: [], isASCIICapable: true)
        #expect(unnamed.displayName == "x.y")
        #expect(InputSourceInfo.korean2Set.displayName == "2-Set Korean")
    }
}

/// 커버리지 점검에서 비어 있던 Core 경로(ADR 0022).
@MainActor
@Suite("Core gaps")
struct CoreGapTests {
    @Test func capsLockAndUnknownUseTheirOwnColors() {
        var settings = KeyHueSettings()
        settings.capsLockColor = RGBAColor(hex: "#112233")!
        settings.unknownColor = RGBAColor(hex: "#445566")!
        #expect(settings.color(for: .capsLock).hexString == "#112233")
        #expect(settings.color(for: .unknown).hexString == "#445566")
        settings.barOpacity = 0.5
        #expect(settings.barColor(for: .capsLock).alpha == 0.5)
    }

    @Test func capsLockAndUnknownColorsPersist() {
        let defaults = makeTestDefaults()
        SettingsStore(defaults: defaults).update {
            $0.capsLockColor = RGBAColor(hex: "#112233")!
            $0.unknownColor = RGBAColor(hex: "#445566")!
        }
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.capsLockColor.hexString == "#112233")
        #expect(reloaded.unknownColor.hexString == "#445566")
    }

    @Test func emptyDefaultSourceIDMeansAutomatic() {
        let defaults = makeTestDefaults()
        defaults.set("", forKey: "defaultSourceID")
        #expect(SettingsStore(defaults: defaults).settings.defaultSourceID == nil)
    }

    @Test func nonFiniteBarHeightFallsBackToDefault() {
        #expect(KeyHueSettings.clampedBarHeight(.nan) == KeyHueSettings().barHeight)
        #expect(KeyHueSettings.clampedBarHeight(.infinity) == KeyHueSettings().barHeight)
    }

    @Test func languageNamesAreAutonyms() {
        #expect(AppLanguage.system.nativeName == nil)
        #expect(AppLanguage.en.nativeName == "English")
        #expect(AppLanguage.ko.nativeName == "한국어")
        #expect(AppLanguage.ja.nativeName == "日本語")
        #expect(AppLanguage.system.lprojName == nil)
        #expect(AppLanguage.ko.lprojName == "ko")
    }

    @Test func subroleAloneMarksTextInput() {
        #expect(TextInputRole.isTextInput(role: "AXGroup", subrole: "AXSearchField"))
    }

    @Test func barOrientation() {
        #expect(BarPosition.top.isHorizontal)
        #expect(BarPosition.bottom.isHorizontal)
        #expect(!BarPosition.left.isHorizontal)
        #expect(!BarPosition.right.isHorizontal)
    }

    @Test func recordingSameSourceTwiceIsANoOp() {
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        memory.record(sourceID: "ko", for: "a")
        defaults.removeObject(forKey: "appInputSources") // 저장을 다시 하는지 확인하려고 지운다
        memory.record(sourceID: "ko", for: "a")
        #expect(defaults.object(forKey: "appInputSources") == nil)
        #expect(memory.entries == ["a": "ko"])
    }
}

@Suite("Accessibility use")
struct AccessibilityUseTests {
    @Test func followsEnabledOptions() {
        var s = KeyHueSettings()
        #expect(s.accessibilityUse.isEmpty)

        s.onAppSwitch = .restoreLast // 앱 옵션은 손쉬운 사용을 쓰지 않는다
        #expect(s.accessibilityUse.isEmpty)

        s.onWindowSwitch = .switchToDefault
        #expect(s.accessibilityUse == AccessibilityUse(textFocus: false, windowSwitches: true))

        s.onWindowSwitch = .restoreLast
        s.resetOnTextFocusLoss = true
        #expect(s.accessibilityUse == AccessibilityUse(textFocus: true, windowSwitches: true))

        s.onWindowSwitch = .keep
        #expect(s.accessibilityUse == AccessibilityUse(textFocus: true, windowSwitches: false))
    }
}
