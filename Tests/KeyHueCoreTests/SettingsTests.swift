import Foundation
import Testing
@testable import KeyHueCore

private func makeDefaults() -> UserDefaults {
    let suite = "KeyHueTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

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
    @Test func defaultsMatchSpec() {
        let settings = SettingsStore(defaults: makeDefaults()).settings
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
        #expect(settings.tintMenuBarIcon)
        #expect(settings.sourceColors.isEmpty)
        #expect(settings.defaultSourceID == nil)
        #expect(settings.appLanguage == .system)
        #expect(settings.showDockIcon)
    }

    @Test func persistsDockIconChoice() {
        let defaults = makeDefaults()
        SettingsStore(defaults: defaults).update { $0.showDockIcon = false }
        #expect(!SettingsStore(defaults: defaults).settings.showDockIcon)
    }

    @Test func persistsAppLanguage() {
        let defaults = makeDefaults()
        SettingsStore(defaults: defaults).update { $0.appLanguage = .en }
        #expect(SettingsStore(defaults: defaults).settings.appLanguage == .en)
        #expect(defaults.string(forKey: "appLanguage") == "en")

        SettingsStore(defaults: defaults).update { $0.appLanguage = .system }
        #expect(defaults.object(forKey: "appLanguage") == nil) // 기본값은 저장하지 않는다
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
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
        }

        let reloaded = SettingsStore(defaults: defaults).settings
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
        let store = SettingsStore(defaults: makeDefaults())
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
        let store = SettingsStore(defaults: makeDefaults())
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
        let defaults = makeDefaults()
        defaults.set("diagonal", forKey: "barPosition")
        #expect(SettingsStore(defaults: defaults).settings.barPosition == .bottom)
    }

    @Test func notifiesOnlyOnChange() {
        let store = SettingsStore(defaults: makeDefaults())
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

    @Test func ignoresCorruptValues() {
        let defaults = makeDefaults()
        defaults.set(["com.apple.keylayout.ABC": "not-a-color"], forKey: "sourceColors")
        defaults.set("sideways", forKey: "displayPolicy")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.sourceColors.isEmpty)
        #expect(settings.displayPolicy == .allScreens)
    }

    // MARK: 기본값과 다른 값만 저장 (ADR 0014)

    @Test func storesOnlyChangedValues() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.barHeight = 8 }
        #expect(defaults.object(forKey: "barHeight") != nil)
        #expect(defaults.object(forKey: "barPosition") == nil)
        #expect(defaults.object(forKey: "showStateBar") == nil)

        store.update { $0.barHeight = KeyHueSettings().barHeight }
        #expect(defaults.object(forKey: "barHeight") == nil)
    }

    @Test func prunesValuesSavedByOlderVersions() {
        let defaults = makeDefaults()
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
        let defaults = makeDefaults()
        let memory = AppInputMemory(defaults: defaults)
        memory.record(sourceID: "ko", for: "com.tinyspeck.slackmacgap")
        memory.record(sourceID: "abc", for: "com.apple.Terminal")

        let reloaded = AppInputMemory(defaults: defaults)
        #expect(reloaded.entries == ["com.tinyspeck.slackmacgap": "ko", "com.apple.Terminal": "abc"])
    }

    @Test func evictsOldestBeyondLimit() {
        let memory = AppInputMemory(defaults: makeDefaults())
        for i in 0...AppInputMemory.maxEntries {
            memory.record(sourceID: "abc", for: "app.\(i)")
        }
        #expect(memory.entries.count == AppInputMemory.maxEntries)
        #expect(memory.entries["app.0"] == nil)
        #expect(memory.entries["app.\(AppInputMemory.maxEntries)"] == "abc")
    }

    @Test func clear() {
        let defaults = makeDefaults()
        let memory = AppInputMemory(defaults: defaults)
        memory.record(sourceID: "ko", for: "a")
        memory.clear()
        #expect(AppInputMemory(defaults: defaults).entries.isEmpty)
    }
}
