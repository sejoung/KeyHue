import Foundation
import Testing
@testable import KeyHueCore

@Suite("Window switch tracker")
struct WindowSwitchTrackerTests {
    @Test func firstMainWindowOnlySetsTheBaseline() {
        var tracker = WindowSwitchTracker<Int>()
        do { let switched = tracker.mainWindowChanged(to: 1); #expect(!switched) }
        do { let switched = tracker.mainWindowChanged(to: 2); #expect(switched) }
    }

    @Test func movingBetweenDifferentWindowsCounts() {
        var tracker = WindowSwitchTracker<Int>()
        tracker.reset(to: 1)
        do { let switched = tracker.mainWindowChanged(to: 2); #expect(switched) } // 창 1 → 창 2
        do { let switched = tracker.mainWindowChanged(to: 1); #expect(switched) } // 다시 창 1
    }

    @Test func sameWindowAgainDoesNotCount() {
        // 대화상자를 닫고 같은 창으로 돌아오거나, 같은 창에 대한 알림이 반복될 때
        var tracker = WindowSwitchTracker<Int>()
        tracker.reset(to: 1)
        do { let switched = tracker.mainWindowChanged(to: 1); #expect(!switched) }
    }

    @Test func missingWindowKeepsTheBaseline() {
        var tracker = WindowSwitchTracker<Int>()
        tracker.reset(to: 1)
        do { let switched = tracker.mainWindowChanged(to: nil); #expect(!switched) }
        do { let switched = tracker.mainWindowChanged(to: 1); #expect(!switched) }
    }

    @Test func appSwitchResetsTheBaseline() {
        // 앱 전환은 별도 옵션이 맡으므로 새 앱의 첫 알림은 세지 않는다
        var tracker = WindowSwitchTracker<Int>()
        tracker.reset(to: 1)
        tracker.reset(to: nil)
        do { let switched = tracker.mainWindowChanged(to: 7); #expect(!switched) }
        do { let switched = tracker.mainWindowChanged(to: 8); #expect(switched) }
    }
}

@Suite("Window switch policy")
struct WindowSwitchPolicyTests {
    private func settings(_ on: Bool) -> KeyHueSettings {
        var s = KeyHueSettings()
        s.onWindowSwitch = on ? .switchToDefault : .keep
        return s
    }

    @Test func switchesToDefaultOnlyWhenEnabled() {
        #expect(ResetPolicy.onWindowSwitched(settings: settings(true), current: .korean2Set) == .selectDefault(preferredID: nil))
        #expect(ResetPolicy.onWindowSwitched(settings: settings(false), current: .korean2Set) == .none)
        #expect(ResetPolicy.onWindowSwitched(settings: settings(true), current: .abc) == .none)
    }

    @Test func needsAccessibility() {
        #expect(PermissionPolicy.missingOnLaunch(settings: settings(true), hasInputMonitoring: true, hasAccessibility: false) == .accessibility)
        #expect(PermissionPolicy.missingOnLaunch(settings: settings(true), hasInputMonitoring: true, hasAccessibility: true) == nil)
    }

    @Test func turningOffAccessibilityFeaturesDisablesWindowSwitchToo() {
        var s = settings(true)
        s.resetOnTextFocusLoss = true
        PermissionPolicy.disableFeature(needing: .accessibility, in: &s)
        #expect(s.onWindowSwitch == .keep)
        #expect(!s.resetOnTextFocusLoss)
    }

    @Test func menuShowsPermissionItemWhenNeeded() {
        let state = StatusMenuState(settings: settings(true), enabledSources: [.abc], escape: .off, textFocus: .off, windowSwitch: .needsPermission)
        #expect(state.showsWindowSwitchPermissionItem)
        #expect(state.windowSwitch == .needsPermission)
    }

    @Test func stalledDetectionIsShownOnlyWhileTheOptionWorks() {
        // 앱이 AX에 끝내 답하지 않으면 메뉴에 알린다. 옵션이 꺼져 있거나 권한이 없으면 그 안내가 먼저다(ADR 0038)
        let on = StatusMenuState(settings: settings(true), enabledSources: [.abc], escape: .off, textFocus: .off,
                                 windowSwitch: .active, windowSwitchStalledApp: "Ghostty")
        #expect(on.windowSwitchStalledApp == "Ghostty")
        let noPermission = StatusMenuState(settings: settings(true), enabledSources: [.abc], escape: .off, textFocus: .off,
                                           windowSwitch: .needsPermission, windowSwitchStalledApp: "Ghostty")
        #expect(noPermission.windowSwitchStalledApp == nil)
        let off = StatusMenuState(settings: settings(false), enabledSources: [.abc], escape: .off, textFocus: .off,
                                  windowSwitch: .off, windowSwitchStalledApp: "Ghostty")
        #expect(off.windowSwitchStalledApp == nil)
    }

    @MainActor
    @Test func persists() {
        let defaults = makeTestDefaults()
        #expect(SettingsStore(defaults: defaults).settings.onWindowSwitch == .keep)
        SettingsStore(defaults: defaults).update { $0.onWindowSwitch = .switchToDefault }
        #expect(defaults.string(forKey: "onWindowSwitch") == "switchToDefault")
        #expect(SettingsStore(defaults: defaults).settings.onWindowSwitch == .switchToDefault)
    }
}

@MainActor
@Suite("Window switch timing")
struct WindowSwitchTimingTests {
    @Test func waitsLikeAppSwitchThenSwitches() {
        let switcher = FakeSwitcher(current: .korean2Set)
        let clock = FakeScheduler()
        var settings = KeyHueSettings()
        settings.onWindowSwitch = .switchToDefault
        let coordinator = AutoResetCoordinator(
            switcher: switcher, scheduler: clock,
            memory: AppInputMemory(defaults: makeTestDefaults())
        ) { settings }
        coordinator.windowSwitched(current: .korean2Set)
        clock.advance(by: AutoResetCoordinator.appSwitchSettleDelay - 0.01)
        #expect(switcher.performed.isEmpty) // macOS가 창별 입력 소스를 되살릴 시간을 준다
        clock.advance(by: 0.01)
        #expect(switcher.currentSource == .abc)
    }
}
