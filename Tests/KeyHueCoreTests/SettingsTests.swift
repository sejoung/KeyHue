import Foundation
import Testing
@testable import KeyHueCore

@Suite("RGBAColor")
struct RGBAColorTests {
    @Test func parsesSixDigitHex() {
        let color = RGBAColor(hex: "#FF8000")
        #expect(color == RGBAColor(red: 1, green: 128.0 / 255, blue: 0))
        #expect(color?.hexString == "#FF8000")
    }

    @Test func parsesEightDigitHex() {
        let color = RGBAColor(hex: "0A84FF80")
        #expect(color?.hexString == "#0A84FF80")
        #expect(color.map { abs($0.alpha - 128.0 / 255) < 0.0001 } == true)
    }

    @Test(arguments: ["", "#12345", "#GGGGGG", "#1234567", "red"])
    func rejectsInvalidHex(_ text: String) {
        #expect(RGBAColor(hex: text) == nil)
    }

    @Test func clampsComponents() {
        let color = RGBAColor(red: 2, green: -1, blue: 0.5)
        #expect(color.red == 1)
        #expect(color.green == 0)
    }
}

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
    @Test func unsupportedStoredLanguageUsesSystemWithEnglishFallback() {
        let defaults = makeTestDefaults()
        defaults.set("fr", forKey: "appLanguage")
        let language = SettingsStore(defaults: defaults).settings.appLanguage
        #expect(language == .system)
        #expect(language.resolved(preferredLanguages: ["fr-FR"]) == .en)
    }

    @Test func defaultsMatchSpec() {
        let settings = SettingsStore(defaults: makeTestDefaults()).settings
        #expect(settings.showStateBar)
        #expect(settings.barHeight == 3)
        #expect(settings.barPosition == .bottom)
        #expect(settings.barOpacity == 1)
        #expect(settings.onAppSwitch == .keep)
        #expect(settings.onWindowSwitch == .keep)
        #expect(!settings.resetOnEscape)
        #expect(settings.displayPolicy == .allScreens)
        #expect(!settings.showHUD)
        #expect(!settings.rememberInputPerApp)
        #expect(!settings.resetOnTextFocusLoss)
        #expect(!settings.warnOnWrongLanguage) // 실험적 기능은 기본으로 꺼 둔다(ADR 0041)
        #expect(settings.wrongLanguageShowsMessage) // 켜면 메시지도 함께 보인다
        #expect(settings.tintMenuBarIcon)
        #expect(settings.sourceColors.isEmpty)
        #expect(settings.defaultSourceID == nil)
        #expect(settings.automaticallyChecksForUpdates)
        #expect(settings.appLanguage == .system)
        #expect(!settings.showDockIcon)
    }

    @Test func persistsAutomaticUpdateChoiceAndRemovesDefault() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.automaticallyChecksForUpdates = false }
        #expect(!SettingsStore(defaults: defaults).settings.automaticallyChecksForUpdates)
        store.update { $0.automaticallyChecksForUpdates = true }
        #expect(defaults.object(forKey: "automaticallyChecksForUpdates") == nil)
    }

    @Test func persistsDockIconChoice() {
        let defaults = makeTestDefaults()
        SettingsStore(defaults: defaults).update { $0.showDockIcon = true }
        #expect(SettingsStore(defaults: defaults).settings.showDockIcon)
    }

    @Test func dockIconShowsWhileSettingsAreOpen() {
        // 메뉴바 전용(기본)이어도 설정 창이 열려 있는 동안은 Dock에 보여 ⌘Tab으로 돌아올 수 있다(ADR 0038)
        var settings = KeyHueSettings()
        #expect(!settings.showsDockIcon(settingsWindowOpen: false))
        #expect(settings.showsDockIcon(settingsWindowOpen: true))
        settings.showDockIcon = true
        #expect(settings.showsDockIcon(settingsWindowOpen: false))
    }

    @Test func persistsAppLanguage() {
        let defaults = makeTestDefaults()
        SettingsStore(defaults: defaults).update { $0.appLanguage = .en }
        #expect(SettingsStore(defaults: defaults).settings.appLanguage == .en)
        #expect(defaults.string(forKey: "appLanguage") == "en")

        SettingsStore(defaults: defaults).update { $0.appLanguage = .system }
        #expect(defaults.object(forKey: "appLanguage") == nil) // 기본값은 저장하지 않는다
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.onAppSwitch = .switchToDefault
            $0.barHeight = 6
            $0.setColor(RGBAColor(hex: "#FF9500")!, for: .korean2Set)
            $0.defaultSourceID = InputSourceInfo.german.id
            $0.displayPolicy = .activeScreen
            $0.showHUD = true
            $0.tintMenuBarIcon = false
            $0.barPosition = .top
            $0.barHeight = 12
            $0.barOpacity = 0.6
            $0.warnOnWrongLanguage = true
            $0.wrongLanguageShowsMessage = false
        }

        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.warnOnWrongLanguage)
        #expect(!reloaded.wrongLanguageShowsMessage)
        #expect(reloaded == store.settings)
        #expect(reloaded.onAppSwitch == .switchToDefault)
        #expect(reloaded.barHeight == 12)
        #expect(reloaded.barPosition == .top)
        #expect(reloaded.barOpacity == 0.6)
        #expect(reloaded.color(for: .korean2Set).hexString == "#FF9500")
        #expect(reloaded.defaultSourceID == InputSourceInfo.german.id)
        #expect(reloaded.displayPolicy == .activeScreen)
        #expect(!reloaded.tintMenuBarIcon)
    }

    @Test func clampsBarHeight() {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.barHeight = 100 }
        #expect(store.settings.barHeight == KeyHueSettings.barHeightRange.upperBound)
        store.update { $0.barHeight = 0 }
        #expect(store.settings.barHeight == KeyHueSettings.barHeightRange.lowerBound)
    }

    @Test func thicknessChoicesGoUpTo16() {
        #expect(KeyHueSettings.barHeightChoices.max() == 16)
        #expect(KeyHueSettings.barHeightChoices.allSatisfy(KeyHueSettings.barHeightRange.contains))
    }

    @Test func clampsBarOpacity() {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.barOpacity = 0 }
        #expect(store.settings.barOpacity == KeyHueSettings.barOpacityRange.lowerBound)
        store.update { $0.barOpacity = 3 }
        #expect(store.settings.barOpacity == 1)
        store.update { $0.barOpacity = .nan }
        #expect(store.settings.barOpacity == 1)
    }

    @Test func barColorAppliesOpacityToStateColorOnly() {
        var settings = KeyHueSettings()
        settings.barOpacity = 0.5
        let state = InputState.source(.korean2Set)
        let bar = settings.barColor(for: state)
        #expect(bar.alpha == 0.5)
        #expect(bar.green == SourcePalette.defaultColor(for: .korean2Set).green)
        #expect(settings.color(for: state).alpha == 1) // HUD/메뉴바 아이콘용 색은 그대로
    }

    @Test func ignoresUnknownPosition() {
        let defaults = makeTestDefaults()
        defaults.set("diagonal", forKey: "barPosition")
        #expect(SettingsStore(defaults: defaults).settings.barPosition == .bottom)
    }

    @Test func notifiesOnlyOnChange() {
        let store = SettingsStore(defaults: makeTestDefaults())
        var count = 0
        store.addObserver { _, _ in count += 1 }
        store.update { $0.showStateBar = true } // 기본값과 동일
        store.update { $0.showStateBar = false }
        #expect(count == 1)
    }

    @Test func resetColors() {
        var settings = KeyHueSettings()
        settings.capsLockColor = RGBAColor(hex: "#000000")!
        settings.setColor(RGBAColor(hex: "#000000")!, for: .abc)
        settings.resetColors()
        #expect(settings.capsLockColor == .defaultCapsLock)
        #expect(settings.sourceColors.isEmpty)
    }

    @Test func perSourceColors() {
        var settings = KeyHueSettings()
        let pink = RGBAColor(hex: "#FF2D55")!
        settings.setColor(pink, for: .hiragana)
        #expect(settings.color(for: .hiragana) == pink)
        #expect(settings.color(for: .katakana) == SourcePalette.defaultColor(for: .katakana)) // 같은 언어라도 별도
        settings.resetColor(for: .hiragana)
        #expect(settings.color(for: .hiragana) == SourcePalette.defaultColor(for: .hiragana))
    }

    @Test func choosingDefaultColorRemovesOverride() {
        var settings = KeyHueSettings()
        settings.setColor(RGBAColor(hex: "#000000")!, for: .abc)
        settings.setColor(SourcePalette.base, for: .abc)
        #expect(settings.sourceColors.isEmpty)
    }

    @Test func oneCorruptColorKeepsTheOthers() {
        let defaults = makeTestDefaults()
        defaults.set(["com.apple.keylayout.ABC": 42, InputSourceInfo.korean2Set.id: "#FF9500"], forKey: "sourceColors")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.sourceColors.count == 1)
        #expect(settings.color(for: .korean2Set).hexString == "#FF9500")
    }

    @Test func ignoresCorruptValues() {
        let defaults = makeTestDefaults()
        defaults.set(["com.apple.keylayout.ABC": "not-a-color"], forKey: "sourceColors")
        defaults.set("sideways", forKey: "displayPolicy")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.sourceColors.isEmpty)
        #expect(settings.displayPolicy == .allScreens)
    }

    // MARK: 기본값과 다른 값만 저장 (ADR 0014)

    @Test func storesOnlyChangedValues() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.barHeight = 8 }
        #expect(defaults.object(forKey: "barHeight") != nil)
        #expect(defaults.object(forKey: "barPosition") == nil)
        #expect(defaults.object(forKey: "showStateBar") == nil)

        store.update { $0.barHeight = KeyHueSettings().barHeight }
        #expect(defaults.object(forKey: "barHeight") == nil)
    }

    @Test func prunesValuesSavedByOlderVersions() {
        let defaults = makeTestDefaults()
        // 이전 버전은 모든 키를 저장했다: 기본값과 같은 값 + 사용자가 바꾼 값 + 레거시 키
        defaults.set("bottom", forKey: "barPosition")
        defaults.set(true, forKey: "showStateBar")
        defaults.set(8.0, forKey: "barHeight")
        defaults.set("#34C759", forKey: "koreanColor")

        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.barHeight == 8)
        #expect(defaults.object(forKey: "barPosition") == nil)
        #expect(defaults.object(forKey: "showStateBar") == nil)
        #expect(defaults.object(forKey: "koreanColor") == nil)
        #expect(defaults.double(forKey: "barHeight") == 8)
    }
}

@MainActor
@Suite("AppInputMemory")
struct AppInputMemoryTests {
    @Test func recordsAndPersists() {
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        memory.record(sourceID: "ko", for: "com.tinyspeck.slackmacgap")
        memory.record(sourceID: "abc", for: "com.apple.Terminal")

        let reloaded = AppInputMemory(defaults: defaults)
        #expect(reloaded.entries == ["com.tinyspeck.slackmacgap": "ko", "com.apple.Terminal": "abc"])
    }

    @Test func evictionOrderSurvivesRelaunch() {
        // 다시 실행한 뒤에도 가장 오래된 앱부터 지운다(사전 순서는 정해져 있지 않다)
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        for index in 0..<AppInputMemory.maxEntries {
            memory.record(sourceID: "s", for: "app\(index)")
        }
        let relaunched = AppInputMemory(defaults: defaults)
        relaunched.record(sourceID: "s", for: "new")
        #expect(relaunched.entries["app0"] == nil)          // 가장 오래된 것
        #expect(relaunched.entries["app1"] == "s")
        #expect(relaunched.entries["new"] == "s")
    }

    @Test func oneCorruptMemoryEntryKeepsTheOthers() {
        let defaults = makeTestDefaults()
        defaults.set(["A": "com.apple.keylayout.ABC", "B": 7], forKey: "appInputSources")
        #expect(AppInputMemory(defaults: defaults).entries == ["A": "com.apple.keylayout.ABC"])
    }

    @Test func evictsOldestBeyondLimit() {
        let memory = AppInputMemory(defaults: makeTestDefaults())
        for i in 0...AppInputMemory.maxEntries {
            memory.record(sourceID: "abc", for: "app.\(i)")
        }
        #expect(memory.entries.count == AppInputMemory.maxEntries)
        #expect(memory.entries["app.0"] == nil)
        #expect(memory.entries["app.\(AppInputMemory.maxEntries)"] == "abc")
    }

    @Test func clear() {
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        memory.record(sourceID: "ko", for: "a")
        memory.clear()
        #expect(AppInputMemory(defaults: defaults).entries.isEmpty)
    }
}

// MARK: - 엣지 케이스

extension KeyHueSettings {
    /// 모든 설정을 기본값과 다르게 바꾼 값. 저장·복원·로그가 설정 하나도 빠뜨리지 않는지 볼 때 쓴다.
    static let everyOptionChanged: KeyHueSettings = {
        var s = KeyHueSettings()
        s.appLanguage = .ja
        s.automaticallyChecksForUpdates = false
        s.showDockIcon = true
        s.showStateBar = false
        s.barHeight = 8
        s.barPosition = .left
        s.barOpacity = 0.4
        s.sourceColors = [InputSourceInfo.abc.id: RGBAColor(hex: "#12345680")!]
        s.capsLockColor = RGBAColor(hex: "#112233")!
        s.unknownColor = RGBAColor(hex: "#445566")!
        s.tintMenuBarIcon = false
        s.onAppSwitch = .restoreLast
        s.resetOnEscape = true
        s.defaultSourceID = InputSourceInfo.german.id
        s.integrateInputMethod = true
        s.routeInputMethodPair = true
        s.displayPolicy = .activeScreen
        s.showHUD = true
        s.resetOnTextFocusLoss = true
        s.onWindowSwitch = .switchToDefault
        s.warnOnWrongLanguage = true
        s.wrongLanguageShowsMessage = false
        return s
    }()

    /// 저장 키 이름은 프로퍼티 이름과 같다.
    static var propertyNames: [String] {
        Mirror(reflecting: KeyHueSettings()).children.compactMap(\.label)
    }
}

@Suite("RGBAColor edge cases")
struct RGBAColorEdgeTests {
    @Test func acceptsSurroundingSpacesAndLowercase() {
        #expect(RGBAColor(hex: "  #ff8000 ")?.hexString == "#FF8000")
        #expect(RGBAColor(hex: "ff8000") == RGBAColor(hex: "#FF8000"))
    }

    @Test(arguments: ["##FF8000", "#FF 8000", "0xFF8000", "#FF80000", "#ＦＦ８０００"])
    func rejectsMalformedHex(_ text: String) {
        #expect(RGBAColor(hex: text) == nil)
    }

    @Test(arguments: ["+FFFFF", "-00000", "#+FFFFF", "#+FFFFFFF", "#-0000000"])
    func rejectsSignCharacters(_ text: String) {
        // `#RRGGBB`/`#RRGGBBAA`는 16진 숫자만이다. 정수 파서가 받아 주는 부호는 색 자리가 아니다.
        #expect(RGBAColor(hex: text) == nil)
    }

    @Test func opaqueEightDigitHexIsTheSameAsSixDigits() {
        #expect(RGBAColor(hex: "#FF8000FF") == RGBAColor(hex: "#FF8000"))
        #expect(RGBAColor(hex: "#FF8000FF")?.hexString == "#FF8000")
        #expect(RGBAColor(hex: "#FF800000")?.hexString == "#FF800000") // 완전 투명은 alpha를 남긴다
    }

    @Test func extremeValues() {
        #expect(RGBAColor(hex: "#000000") == RGBAColor(red: 0, green: 0, blue: 0))
        #expect(RGBAColor(hex: "#FFFFFFFF") == RGBAColor(red: 1, green: 1, blue: 1))
        #expect(RGBAColor(hex: "00000000")?.alpha == 0)
        #expect(RGBAColor(red: 0, green: 0, blue: 0, alpha: 0).hexString == "#00000000")
    }

    @Test func everyByteRoundTripsThroughHex() {
        for byte in 0...255 {
            let hex = String(format: "#%02X%02X%02X%02X", byte, 255 - byte, byte, byte == 255 ? 254 : byte)
            #expect(RGBAColor(hex: hex)?.hexString == hex)
        }
    }

    @Test func nearlyOpaqueAlphaIsWrittenAsSixDigits() {
        // 반올림해서 0xFF가 되는 alpha는 불투명으로 적는다
        #expect(RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.999).hexString == "#FF0000")
        #expect(RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.997).hexString == "#FF0000FE")
    }

    @Test func clampsInfiniteComponents() {
        let color = RGBAColor(red: .infinity, green: -.infinity, blue: 0.5, alpha: .infinity)
        #expect(color.red == 1)
        #expect(color.green == 0)
        #expect(color.alpha == 1)
    }

    @Test func nanComponentsAreClampedIntoRange() {
        // 범위를 벗어난 값은 0...1로 자른다. NaN이 남으면 hexString(Int 변환)에서 앱이 멈춘다.
        let color = RGBAColor(red: .nan, green: 0, blue: 0, alpha: .nan)
        #expect((0...1).contains(color.red))
        #expect((0...1).contains(color.alpha))
    }
}

@MainActor
@Suite("SettingsStore edge cases")
struct SettingsStoreEdgeTests {
    @Test func everySettingIsSavedRestoredAndPruned() {
        // 새 설정을 추가하면서 save/load 한쪽을 빠뜨리면 여기서 잡힌다
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        let changed = KeyHueSettings.everyOptionChanged
        #expect(changed.nonDefaultDescriptions.count == KeyHueSettings.propertyNames.count)
        store.update { $0 = changed }
        for name in KeyHueSettings.propertyNames {
            #expect(defaults.object(forKey: name) != nil, "\(name) is not saved")
        }
        #expect(SettingsStore(defaults: defaults).settings == changed)

        store.update { $0 = KeyHueSettings() }
        for name in KeyHueSettings.propertyNames {
            #expect(defaults.object(forKey: name) == nil, "\(name) is kept although it is the default")
        }
        #expect(SettingsStore(defaults: defaults).settings == KeyHueSettings())
    }

    @Test func storedValuesEqualToDefaultsArePruned() {
        let defaults = makeTestDefaults()
        defaults.set(RGBAColor.defaultCapsLock.hexString, forKey: "capsLockColor")
        defaults.set(RGBAColor.defaultUnknown.hexString, forKey: "unknownColor")
        defaults.set([String: String](), forKey: "sourceColors")
        defaults.set("system", forKey: "appLanguage")
        defaults.set("keep", forKey: "onAppSwitch")
        defaults.set("", forKey: "defaultSourceID")
        defaults.set(1.0, forKey: "barOpacity")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings == KeyHueSettings())
        for key in ["capsLockColor", "unknownColor", "sourceColors", "appLanguage", "onAppSwitch", "defaultSourceID", "barOpacity"] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test func outOfRangeStoredNumbersAreClampedAndRewritten() {
        let defaults = makeTestDefaults()
        defaults.set(100.0, forKey: "barHeight")
        defaults.set(0.05, forKey: "barOpacity")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.barHeight == KeyHueSettings.barHeightRange.upperBound)
        #expect(settings.barOpacity == KeyHueSettings.barOpacityRange.lowerBound)
        #expect(defaults.double(forKey: "barHeight") == KeyHueSettings.barHeightRange.upperBound)
        #expect(defaults.double(forKey: "barOpacity") == KeyHueSettings.barOpacityRange.lowerBound)
    }

    @Test func storedFractionalHeightThatRoundsToDefaultIsPruned() {
        let defaults = makeTestDefaults()
        defaults.set(3.4, forKey: "barHeight")
        #expect(SettingsStore(defaults: defaults).settings.barHeight == 3)
        #expect(defaults.object(forKey: "barHeight") == nil)
    }

    @Test func clampingBoundaries() {
        #expect(KeyHueSettings.clampedBarHeight(2.5) == 3)
        #expect(KeyHueSettings.clampedBarHeight(2.49) == 2)
        #expect(KeyHueSettings.clampedBarHeight(0.5) == 1)
        #expect(KeyHueSettings.clampedBarHeight(-5) == 1)
        #expect(KeyHueSettings.clampedBarHeight(16.4) == 16)
        #expect(KeyHueSettings.clampedBarHeight(-.infinity) == KeyHueSettings().barHeight)
        #expect(KeyHueSettings.clampedBarOpacity(0.2) == 0.2)
        #expect(KeyHueSettings.clampedBarOpacity(0.19) == 0.2)
        #expect(KeyHueSettings.clampedBarOpacity(0.55) == 0.55) // 두께와 달리 반올림하지 않는다
        #expect(KeyHueSettings.clampedBarOpacity(.infinity) == 1)
        #expect(KeyHueSettings.clampedBarOpacity(-.infinity) == 1)
    }

    @Test func corruptColorValuesFallBackToDefaults() {
        let defaults = makeTestDefaults()
        defaults.set("#GG0000", forKey: "capsLockColor")
        defaults.set(42, forKey: "unknownColor")
        defaults.set("not a dictionary", forKey: "sourceColors")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.capsLockColor == .defaultCapsLock)
        #expect(settings.unknownColor == .defaultUnknown)
        #expect(settings.sourceColors.isEmpty)
        // 깨진 값은 다음 저장에서 지워진다
        #expect(defaults.object(forKey: "capsLockColor") == nil)
        #expect(defaults.object(forKey: "unknownColor") == nil)
        #expect(defaults.object(forKey: "sourceColors") == nil)
    }

    @Test func unknownEnumValuesFallBackAndArePruned() {
        let defaults = makeTestDefaults()
        defaults.set("rememberLast", forKey: "onAppSwitch")
        defaults.set("sometimes", forKey: "onWindowSwitch")
        defaults.set("Top", forKey: "barPosition") // 대소문자도 정확히 맞아야 한다
        defaults.set("de", forKey: "appLanguage")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.onAppSwitch == .keep)
        #expect(settings.onWindowSwitch == .keep)
        #expect(settings.barPosition == .bottom)
        #expect(settings.appLanguage == .system)
        for key in ["onAppSwitch", "onWindowSwitch", "barPosition", "appLanguage"] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test func newSwitchKeysWinOverOldOnes() {
        // 새 키가 이미 있으면 옛 키로 덮어쓰지 않고, 옛 키는 지운다(ADR 0029)
        let defaults = makeTestDefaults()
        defaults.set("switchToDefault", forKey: "onAppSwitch")
        defaults.set("keep", forKey: "onWindowSwitch")
        defaults.set(true, forKey: "rememberInputPerApp")
        defaults.set(true, forKey: "rememberInputPerWindow")
        defaults.set("perWindow", forKey: "inputMemory")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.onAppSwitch == .switchToDefault)
        #expect(settings.onWindowSwitch == .keep)
        for key in ["rememberInputPerApp", "rememberInputPerWindow", "inputMemory"] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(SettingsStore(defaults: defaults).settings.onAppSwitch == .switchToDefault)
    }

    @Test func sourceColorsWithAlphaRoundTrip() {
        let defaults = makeTestDefaults()
        let colors = [
            InputSourceInfo.abc.id: RGBAColor(hex: "#00000000")!,
            InputSourceInfo.korean2Set.id: RGBAColor(hex: "#FF950080")!,
            InputSourceInfo.hiragana.id: RGBAColor(hex: "#FFFFFF")!
        ]
        SettingsStore(defaults: defaults).update { $0.sourceColors = colors }
        #expect(SettingsStore(defaults: defaults).settings.sourceColors == colors)
    }

    @Test func clampingToTheCurrentValueIsNotAChange() {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.barHeight = 16 }
        var count = 0
        store.addObserver { _, _ in count += 1 }
        store.update { $0.barHeight = 100 }   // 16으로 잘려서 그대로
        store.update { $0.barHeight = 16.2 }  // 반올림해서 그대로
        store.update { $0.barOpacity = 5 }    // 1로 잘려서 기본값 그대로
        #expect(count == 0)
        #expect(store.settings.barHeight == 16)
    }

    @Test func everyObserverGetsClampedOldAndNewInOrder() {
        let store = SettingsStore(defaults: makeTestDefaults())
        var calls: [String] = []
        store.addObserver { old, new in calls.append("a \(old.barHeight)→\(new.barHeight)") }
        store.addObserver { old, new in calls.append("b \(old.barHeight)→\(new.barHeight)") }
        store.update { $0.barHeight = 99 }
        #expect(calls == ["a 3.0→16.0", "b 3.0→16.0"])
        #expect(store.settings.barHeight == 16)
    }

    @Test func systemLanguageIgnoresUnusableTags() {
        // "system"은 실제 언어가 아니고, 빈 태그는 건너뛴다
        #expect(AppLanguage.system.resolved(preferredLanguages: ["system"]) == .en)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["", "system", "KO"]) == .ko)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "ja"]) == .ja)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["english", "ko"]) == .ko) // 코드가 아닌 태그는 건너뛴다
        #expect(AppLanguage.ko.resolved(preferredLanguages: []) == .ko)
    }
}

/// 깨진 값은 그 항목만 기본값으로 읽고 키를 지운다. 색과 같은 규칙(ADR 0043, 2026-10-03 보완).
@MainActor
@Suite("SettingsStore corrupt values")
struct SettingsStoreCorruptValueTests {
    @Test func corruptBooleansFallBackToTheirDefaultsAndAreRemoved() {
        let defaults = makeTestDefaults()
        defaults.set("garbage", forKey: "showStateBar")   // default true
        defaults.set("maybe", forKey: "resetOnEscape")    // default false
        defaults.set(["x"], forKey: "tintMenuBarIcon")    // default true
        defaults.set(Date(), forKey: "showHUD")           // default false
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.showStateBar)
        #expect(!store.settings.resetOnEscape)
        #expect(store.settings.tintMenuBarIcon)
        #expect(!store.settings.showHUD)
        for key in ["showStateBar", "resetOnEscape", "tintMenuBarIcon", "showHUD"] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
        #expect(Set(store.ignoredKeys) == ["showStateBar", "resetOnEscape", "tintMenuBarIcon", "showHUD"])
    }

    @Test(arguments: [("YES", true), ("yes", true), ("true", true), ("TRUE", true), ("1", true),
                      ("NO", false), ("no", false), ("false", false), ("0", false), (" true ", true)])
    func booleanWordsWrittenByHandAreRead(text: String, expected: Bool) {
        let defaults = makeTestDefaults()
        defaults.set(text, forKey: "resetOnEscape")
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.resetOnEscape == expected)
        #expect(store.ignoredKeys.isEmpty)
    }

    @Test func realBooleansAndNumbersAreRead() {
        let defaults = makeTestDefaults()
        defaults.set(false, forKey: "showStateBar")
        defaults.set(1, forKey: "resetOnEscape")
        let store = SettingsStore(defaults: defaults)
        #expect(!store.settings.showStateBar)
        #expect(store.settings.resetOnEscape)
        #expect(store.ignoredKeys.isEmpty)
    }

    @Test func corruptNumbersFallBackToTheirDefaultsAndAreRemoved() {
        let defaults = makeTestDefaults()
        defaults.set("garbage", forKey: "barHeight")      // default 3, previously read as 0 → 1
        defaults.set(Double.nan, forKey: "barOpacity")    // default 1, previously clamped to 0.2
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.barHeight == KeyHueSettings().barHeight)
        #expect(store.settings.barOpacity == KeyHueSettings().barOpacity)
        #expect(defaults.object(forKey: "barHeight") == nil)
        #expect(defaults.object(forKey: "barOpacity") == nil)
        #expect(Set(store.ignoredKeys) == ["barHeight", "barOpacity"])
    }

    @Test func infiniteOrBooleanTypedNumbersAreNotValidSizes() {
        let defaults = makeTestDefaults()
        defaults.set(Double.infinity, forKey: "barHeight")
        defaults.set(true, forKey: "barOpacity")
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.barHeight == KeyHueSettings().barHeight)
        #expect(store.settings.barOpacity == KeyHueSettings().barOpacity)
        #expect(Set(store.ignoredKeys) == ["barHeight", "barOpacity"])
    }

    @Test func numericTextIsRead() {
        let defaults = makeTestDefaults()
        defaults.set("5", forKey: "barHeight")
        defaults.set(" 0.5 ", forKey: "barOpacity")
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.barHeight == 5)
        #expect(store.settings.barOpacity == 0.5)
        #expect(store.ignoredKeys.isEmpty)
    }

    @Test func oneCorruptValueLeavesTheOtherSettingsAlone() {
        let defaults = makeTestDefaults()
        defaults.set("garbage", forKey: "showStateBar")
        defaults.set(true, forKey: "resetOnEscape")
        defaults.set(6.0, forKey: "barHeight")
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.showStateBar)
        #expect(store.settings.resetOnEscape)
        #expect(store.settings.barHeight == 6)
        #expect(store.ignoredKeys == ["showStateBar"])
    }

    @Test func unreadableChoicesAndColorsAreReportedToo() {
        let defaults = makeTestDefaults()
        defaults.set("sideways", forKey: "barPosition")
        defaults.set("#nothex", forKey: "capsLockColor")
        defaults.set(["com.apple.keylayout.ABC": "#112233", "broken": 7], forKey: "sourceColors")
        let store = SettingsStore(defaults: defaults)
        #expect(Set(store.ignoredKeys) == ["barPosition", "capsLockColor", "sourceColors"])
        #expect(store.settings.sourceColors.keys.sorted() == ["com.apple.keylayout.ABC"])
    }

    @Test func freshAndCleanStoresIgnoreNothing() {
        #expect(SettingsStore(defaults: makeTestDefaults()).ignoredKeys.isEmpty)
        let defaults = makeTestDefaults()
        let first = SettingsStore(defaults: defaults)
        first.update {
            $0.showStateBar = false
            $0.barHeight = 8
            $0.barPosition = .top
        }
        #expect(SettingsStore(defaults: defaults).ignoredKeys.isEmpty)
    }
}
