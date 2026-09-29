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
        #expect(!settings.resetOnAppSwitch)
        #expect(!settings.resetOnEscape)
        #expect(settings.displayPolicy == .allScreens)
        #expect(!settings.showHUD)
        #expect(!settings.rememberInputPerApp)
        #expect(!settings.resetOnTextFocusLoss)
        #expect(settings.tintMenuBarIcon)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.resetOnAppSwitch = true
            $0.barHeight = 6
            $0.koreanColor = RGBAColor(hex: "#FF9500")!
            $0.displayPolicy = .activeScreen
            $0.showHUD = true
            $0.tintMenuBarIcon = false
            $0.barPosition = .top
            $0.barHeight = 12
            $0.barOpacity = 0.6
        }

        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded == store.settings)
        #expect(reloaded.resetOnAppSwitch)
        #expect(reloaded.barHeight == 12)
        #expect(reloaded.barPosition == .top)
        #expect(reloaded.barOpacity == 0.6)
        #expect(reloaded.koreanColor.hexString == "#FF9500")
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
        let bar = settings.barColor(for: .korean)
        #expect(bar.alpha == 0.5)
        #expect(bar.green == RGBAColor.defaultKorean.green)
        #expect(settings.color(for: .korean).alpha == 1) // HUD/메뉴바 아이콘용 색은 그대로
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
        settings.setColor(RGBAColor(hex: "#000000")!, for: .capsLock)
        settings.resetColors()
        #expect(settings.capsLockColor == .defaultCapsLock)
    }

    @Test func ignoresCorruptValues() {
        let defaults = makeDefaults()
        defaults.set("not-a-color", forKey: "koreanColor")
        defaults.set("sideways", forKey: "displayPolicy")
        let settings = SettingsStore(defaults: defaults).settings
        #expect(settings.koreanColor == .defaultKorean)
        #expect(settings.displayPolicy == .allScreens)
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
