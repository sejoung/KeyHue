import Foundation
import Testing
@testable import KeyHueCore

private let terminal = "com.mitchellh.ghostty"
private let messenger = "com.kakao.KakaoTalkMac"

/// ADR 0089: 고른 앱만 창마다 기억하고, 나머지 앱은 앱 하나로 기억한다.
@Suite("Apps that remember each window")
struct WindowMemoryAppsPolicyTests {
    private func settings(app: SwitchBehavior = .restoreLast, window: SwitchBehavior = .keep, apps: [String] = [terminal]) -> KeyHueSettings {
        var settings = KeyHueSettings()
        settings.onAppSwitch = app
        settings.onWindowSwitch = window
        settings.windowMemoryApps = apps
        return settings
    }

    @Test func onlyListedAppsRestoreEachWindow() {
        let s = settings()
        #expect(s.windowSwitchBehavior(in: terminal) == .restoreLast)
        #expect(s.windowSwitchBehavior(in: messenger) == .keep)
        #expect(s.windowSwitchBehavior(in: nil) == .keep)
        #expect(s.remembersInputPerWindow(in: terminal))
        #expect(!s.remembersInputPerWindow(in: messenger))
        #expect(s.rememberInputPerWindow && s.watchesWindowSwitches && s.usesAccessibility)
    }

    @Test func otherAppsFollowTheWindowOption() {
        let s = settings(window: .switchToDefault)
        #expect(s.windowSwitchBehavior(in: terminal) == .restoreLast)
        #expect(s.windowSwitchBehavior(in: messenger) == .switchToDefault)
    }

    @Test(arguments: [SwitchBehavior.keep, .switchToDefault])
    func theListAppliesOnlyWhileAppsAreRestored(_ app: SwitchBehavior) {
        let s = settings(app: app)
        #expect(!s.appliesWindowMemoryApps)
        #expect(s.windowSwitchBehavior(in: terminal) == .keep)
        #expect(!s.rememberInputPerWindow && !s.watchesWindowSwitches && !s.usesAccessibility)
        #expect(s.windowMemoryApps == [terminal]) // 지우지 않는다
    }

    @Test func theListIsMootWhenEveryWindowIsRestored() {
        let s = settings(window: .restoreLast)
        #expect(!s.appliesWindowMemoryApps)
        #expect(s.windowSwitchBehavior(in: messenger) == .restoreLast)
    }

    @Test func anEmptyListNeedsNoPermission() {
        let s = settings(apps: [])
        #expect(!s.watchesWindowSwitches && !s.rememberInputPerWindow)
        #expect(PermissionPolicy.missingOnLaunch(settings: s, hasInputMonitoring: true, hasAccessibility: false) == nil)
    }

    @Test func turningOffAccessibilityEmptiesTheList() {
        var s = settings()
        #expect(PermissionPolicy.missingOnLaunch(settings: s, hasInputMonitoring: true, hasAccessibility: false) == .accessibility)
        PermissionPolicy.disableFeature(needing: .accessibility, in: &s)
        #expect(s.windowMemoryApps.isEmpty)
        #expect(!PermissionKind.accessibility.isUsed(by: s))
    }

    @Test func windowSwitchPolicyUsesTheAppsBehavior() {
        let s = settings()
        #expect(ResetPolicy.onWindowSwitched(settings: s, bundleID: terminal, rememberedForWindow: InputSourceInfo.korean2Set.id,
                                             current: .abc) == .select(sourceID: InputSourceInfo.korean2Set.id))
        #expect(ResetPolicy.onWindowSwitched(settings: s, bundleID: terminal, current: .korean2Set) == .selectDefault(preferredID: nil))
        #expect(ResetPolicy.onWindowSwitched(settings: s, bundleID: messenger, rememberedForWindow: InputSourceInfo.abc.id,
                                             current: .korean2Set) == .none)
    }

    @Test func comingBackUsesTheFrontWindowOnlyInAppsThatRememberEachWindow() {
        let s = settings()
        let remembered = [terminal: InputSourceInfo.abc.id, messenger: InputSourceInfo.abc.id]
        #expect(ResetPolicy.onAppActivated(bundleID: terminal, settings: s, remembered: remembered,
                                           rememberedForWindow: InputSourceInfo.korean2Set.id, current: .abc)
                == .select(sourceID: InputSourceInfo.korean2Set.id))
        #expect(ResetPolicy.onAppActivated(bundleID: messenger, settings: s, remembered: remembered,
                                           rememberedForWindow: InputSourceInfo.korean2Set.id, current: .korean2Set)
                == .select(sourceID: InputSourceInfo.abc.id))
    }

    @Test func menuOffersTheFrontAppWhileTheListApplies() {
        let ghostty = FrontApp(bundleID: terminal, name: "Ghostty")
        let kakao = FrontApp(bundleID: messenger, name: "KakaoTalk")
        let on = StatusMenuState(settings: settings(), enabledSources: [.abc], escape: .off, textFocus: .off, frontApp: ghostty)
        #expect(on.windowMemoryApp == ghostty)
        #expect(on.remembersEachWindowInFrontApp)
        let off = StatusMenuState(settings: settings(), enabledSources: [.abc], escape: .off, textFocus: .off, frontApp: kakao)
        #expect(off.windowMemoryApp == kakao)
        #expect(!off.remembersEachWindowInFrontApp)
        #expect(StatusMenuState(settings: settings(), enabledSources: [.abc], escape: .off, textFocus: .off).windowMemoryApp == nil)
        for hidden in [settings(app: .keep), settings(window: .restoreLast)] {
            #expect(StatusMenuState(settings: hidden, enabledSources: [.abc], escape: .off, textFocus: .off, frontApp: ghostty).windowMemoryApp == nil)
        }
    }

    @MainActor @Test func persistsAndLogsTheBundleIDs() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.windowMemoryApps = [terminal, messenger] }
        #expect(SettingsStore(defaults: defaults).settings.windowMemoryApps == [terminal, messenger])
        let changes = KeyHueSettings.changeDescriptions(from: KeyHueSettings(), to: store.settings)
        #expect(changes.contains { $0.contains("windowMemoryApps") && $0.contains(terminal) })
        store.update { $0.windowMemoryApps = [] }
        #expect(defaults.object(forKey: "windowMemoryApps") == nil)
    }

    @Test func forgettingAnAppKeepsTheOtherAppsWindows() {
        var memory = WindowInputMemory<Int>()
        memory.record(sourceID: "a", for: 1, app: terminal)
        memory.record(sourceID: "b", for: 2, app: messenger)
        memory.record(sourceID: "c", for: 3, app: terminal)
        memory.forget(app: terminal)
        #expect(memory.count == 1)
        #expect(memory.source(for: 2) == "b")
        memory.record(sourceID: "d", for: 4, app: terminal)
        #expect(memory.source(for: 4) == "d")
    }
}

/// 실제 흐름: Ghostty는 탭마다, 카카오톡은 앱 하나로 기억한다.
@MainActor
@Suite("Apps that remember each window: flow")
struct WindowMemoryAppsFlowTests {
    @MainActor
    private final class Harness {
        var settings = KeyHueSettings()
        let switcher = FakeSwitcher(current: .abc)
        let clock = FakeScheduler()
        lazy var coordinator = AutoResetCoordinator(
            switcher: switcher, scheduler: clock,
            memory: AppInputMemory(defaults: makeTestDefaults())
        ) { [unowned self] in self.settings }

        init() {
            settings.onAppSwitch = .restoreLast
            settings.windowMemoryApps = [terminal]
        }

        func userSelects(_ source: InputSourceInfo, in app: String, window: Int) {
            let old = switcher.currentSource
            switcher.currentSource = source
            coordinator.sourceChanged(from: old, to: source, activeBundleID: app, activeWindow: window)
        }

        func switchWindow(in app: String, from previous: Int, to window: Int) {
            coordinator.windowSwitched(from: previous, to: window, in: app, current: switcher.currentSource)
            clock.advance(by: 1)
        }

        func activate(_ app: String, from previous: String, leaving previousWindow: Int, front window: Int) {
            coordinator.appActivated(previousBundleID: previous, currentBundleID: app, sourceBeforeActivation: switcher.currentSource,
                                     previousWindow: previousWindow, currentWindow: { window })
            clock.advance(by: 1)
        }

        func update(_ change: (inout KeyHueSettings) -> Void) {
            let old = settings
            change(&settings)
            coordinator.settingsChanged(from: old, to: settings)
        }
    }

    @Test func terminalTabsAreRememberedAndMessengerRoomsKeepTheSource() {
        let h = Harness()
        h.userSelects(.korean2Set, in: terminal, window: 1)       // 커밋 메시지 탭
        h.switchWindow(in: terminal, from: 1, to: 2)                // 새 탭 → 기본
        #expect(h.switcher.currentSource == .abc)
        h.switchWindow(in: terminal, from: 2, to: 1)
        #expect(h.switcher.currentSource == .korean2Set)

        h.activate(messenger, from: terminal, leaving: 1, front: 10)
        #expect(h.switcher.currentSource == .abc)                   // 처음 가는 앱 → 기본
        h.userSelects(.korean2Set, in: messenger, window: 10)
        h.switchWindow(in: messenger, from: 10, to: 11)             // 다른 채팅방
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.coordinator.windowMemory.source(for: 10) == nil)  // 메신저 창은 기록하지 않는다

        h.activate(terminal, from: messenger, leaving: 11, front: 2)
        #expect(h.switcher.currentSource == .abc)                   // 탭 2의 기록
        h.activate(messenger, from: terminal, leaving: 2, front: 10)
        #expect(h.switcher.currentSource == .korean2Set)            // 메신저는 앱 기록
    }

    @Test func removingAnAppForgetsOnlyItsWindows() {
        let h = Harness()
        h.settings.windowMemoryApps = [terminal, "com.apple.Terminal"]
        h.userSelects(.korean2Set, in: terminal, window: 1)
        h.userSelects(.hiragana, in: "com.apple.Terminal", window: 5)
        h.update { $0.windowMemoryApps = ["com.apple.Terminal"] }
        #expect(h.coordinator.windowMemory.source(for: 1) == nil)
        #expect(h.coordinator.windowMemory.source(for: 5) == InputSourceInfo.hiragana.id)
        // 뺀 앱은 앱 하나로 기억한다: 탭을 바꿔도 그대로
        h.switchWindow(in: terminal, from: 2, to: 1)
        #expect(h.switcher.currentSource == .hiragana)
    }

    @Test func theListStoppingToApplyForgetsItsWindows() {
        let h = Harness()
        h.userSelects(.korean2Set, in: terminal, window: 1)
        h.update { $0.onWindowSwitch = .restoreLast }               // 모든 앱이 창마다: 기록은 그대로 쓴다
        #expect(h.coordinator.windowMemory.source(for: 1) == InputSourceInfo.korean2Set.id)
        h.update { $0.onWindowSwitch = .keep }
        h.update { $0.onAppSwitch = .keep }                         // 목록이 적용되지 않는다
        #expect(h.coordinator.windowMemory.count == 0)
        #expect(h.settings.windowMemoryApps == [terminal])
    }
}
