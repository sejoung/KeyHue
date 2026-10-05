import Foundation
import Testing
@testable import KeyHueCore

// 창별 입력 소스 기억 (ADR 0028)

@Suite("Window input memory")
struct WindowInputMemoryTests {
    @Test func recordsAndOverwritesPerWindow() {
        var memory = WindowInputMemory<Int>()
        memory.record(sourceID: "ko", for: 1)
        memory.record(sourceID: "abc", for: 2)
        memory.record(sourceID: "ja", for: 1)
        #expect(memory.source(for: 1) == "ja")
        #expect(memory.source(for: 2) == "abc")
        #expect(memory.source(for: 3) == nil)
        #expect(memory.count == 2)
    }

    @Test func dropsTheLeastRecentlyUsedWindowWhenFull() {
        var memory = WindowInputMemory<Int>()
        for window in 0..<WindowInputMemory<Int>.capacity {
            memory.record(sourceID: "s\(window)", for: window)
        }
        memory.record(sourceID: "again", for: 0) // 0번 창을 다시 써서 가장 최근이 된다
        memory.record(sourceID: "new", for: 999)
        #expect(memory.count == WindowInputMemory<Int>.capacity)
        #expect(memory.source(for: 0) == "again")
        #expect(memory.source(for: 1) == nil) // 가장 오래된 창이 빠진다
        #expect(memory.source(for: 999) == "new")
    }

    @Test func clearForgetsEverything() {
        var memory = WindowInputMemory<Int>()
        memory.record(sourceID: "ko", for: 1)
        memory.clear()
        #expect(memory.count == 0)
        #expect(memory.source(for: 1) == nil)
    }
}

@Suite("Switch behavior policy")
struct SwitchBehaviorPolicyTests {
    private func settings(app: SwitchBehavior = .keep, window: SwitchBehavior = .restoreLast) -> KeyHueSettings {
        var s = KeyHueSettings()
        s.onAppSwitch = app
        s.onWindowSwitch = window
        return s
    }

    @Test func behaviorDecidesWhatIsRemembered() {
        #expect(!settings(app: .keep, window: .keep).rememberInputPerApp)
        #expect(!settings(app: .switchToDefault, window: .switchToDefault).rememberInputPerWindow)
        #expect(settings(app: .restoreLast, window: .keep).rememberInputPerApp)
        #expect(!settings(app: .restoreLast, window: .keep).rememberInputPerWindow)
        #expect(settings(app: .keep, window: .restoreLast).rememberInputPerWindow)
        #expect(!settings(app: .keep, window: .keep).watchesWindowSwitches)
        #expect(settings(window: .switchToDefault).watchesWindowSwitches)
        #expect(settings(window: .restoreLast).watchesWindowSwitches)
    }

    // MARK: 창을 바꿀 때

    @Test func windowRestoresItsSource() {
        let action = ResetPolicy.onWindowSwitched(settings: settings(), rememberedForWindow: InputSourceInfo.korean2Set.id, current: .abc)
        #expect(action == .select(sourceID: InputSourceInfo.korean2Set.id))
    }

    @Test func windowRestoreDoesNothingWhenAlreadyThere() {
        let action = ResetPolicy.onWindowSwitched(settings: settings(), rememberedForWindow: InputSourceInfo.abc.id, current: .abc)
        #expect(action == .none)
    }

    @Test func unknownWindowSwitchesToDefault() {
        // ⌘N으로 연 새 창 등 처음 보는 창은 기본 입력 소스로 시작한다
        #expect(ResetPolicy.onWindowSwitched(settings: settings(), rememberedForWindow: nil, current: .korean2Set) == .selectDefault(preferredID: nil))
    }

    @Test func windowSwitchToDefaultIgnoresMemory() {
        let action = ResetPolicy.onWindowSwitched(settings: settings(window: .switchToDefault), rememberedForWindow: InputSourceInfo.korean2Set.id, current: .hiragana)
        #expect(action == .selectDefault(preferredID: nil))
    }

    @Test func windowKeepDoesNothing() {
        #expect(ResetPolicy.onWindowSwitched(settings: settings(window: .keep), rememberedForWindow: InputSourceInfo.korean2Set.id, current: .abc) == .none)
        #expect(ResetPolicy.onWindowSwitched(settings: settings(window: .keep), rememberedForWindow: nil, current: .korean2Set) == .none)
    }

    // MARK: 앱을 바꿀 때

    @Test func appRestorePrefersTheFrontWindow() {
        let remembered = ["com.apple.Terminal": InputSourceInfo.hiragana.id]
        let action = ResetPolicy.onAppActivated(
            bundleID: "com.apple.Terminal", settings: settings(app: .restoreLast), remembered: remembered,
            rememberedForWindow: InputSourceInfo.korean2Set.id, current: .abc
        )
        #expect(action == .select(sourceID: InputSourceInfo.korean2Set.id))
    }

    @Test func appRestoreFallsBackToTheAppThenDefault() {
        let remembered = ["com.apple.Terminal": InputSourceInfo.hiragana.id]
        let known = ResetPolicy.onAppActivated(
            bundleID: "com.apple.Terminal", settings: settings(app: .restoreLast), remembered: remembered,
            rememberedForWindow: nil, current: .abc
        )
        #expect(known == .select(sourceID: InputSourceInfo.hiragana.id))
        let firstVisit = ResetPolicy.onAppActivated(
            bundleID: "new.app", settings: settings(app: .restoreLast), remembered: remembered,
            rememberedForWindow: nil, current: .korean2Set
        )
        #expect(firstVisit == .selectDefault(preferredID: nil))
    }

    @Test func appRestoreIgnoresWindowsWhenWindowsAreNotRestored() {
        let action = ResetPolicy.onAppActivated(
            bundleID: "com.apple.Terminal", settings: settings(app: .restoreLast, window: .switchToDefault), remembered: [:],
            rememberedForWindow: InputSourceInfo.korean2Set.id, current: .abc
        )
        #expect(action == .none) // 창 기록은 쓰지 않고, 처음 가는 앱이라 기본 입력 소스(이미 ABC)
    }

    @Test func appSwitchRuleGovernsAppActivation() {
        // 창은 복원이어도 앱 전환이 "ABC로 전환"이면 앱으로 돌아올 때는 ABC
        let toDefault = ResetPolicy.onAppActivated(
            bundleID: "com.apple.Terminal", settings: settings(app: .switchToDefault), remembered: [:],
            rememberedForWindow: InputSourceInfo.korean2Set.id, current: .hiragana
        )
        #expect(toDefault == .selectDefault(preferredID: nil))
        let keep = ResetPolicy.onAppActivated(
            bundleID: "com.apple.Terminal", settings: settings(app: .keep), remembered: [:],
            rememberedForWindow: InputSourceInfo.korean2Set.id, current: .hiragana
        )
        #expect(keep == .none)
    }

    // MARK: 권한·메뉴·저장

    @Test func windowOptionsNeedAccessibility() {
        for behavior in [SwitchBehavior.switchToDefault, .restoreLast] {
            var s = settings(app: .restoreLast, window: behavior)
            #expect(PermissionPolicy.missingOnLaunch(settings: s, hasInputMonitoring: false, hasAccessibility: false) == .accessibility)
            #expect(PermissionPolicy.missingOnLaunch(settings: s, hasInputMonitoring: false, hasAccessibility: true) == nil)
            // "끄기"를 고르면 창 옵션만 그대로 두기로, 앱 옵션(권한 불필요)은 유지
            PermissionPolicy.disableFeature(needing: .accessibility, in: &s)
            #expect(s.onWindowSwitch == .keep)
            #expect(s.onAppSwitch == .restoreLast)
        }
        #expect(PermissionPolicy.missingOnLaunch(settings: settings(app: .restoreLast, window: .keep), hasInputMonitoring: false, hasAccessibility: false) == nil)
    }

    @Test func menuState() {
        let state = StatusMenuState(
            settings: settings(app: .switchToDefault, window: .restoreLast), enabledSources: [.abc],
            escape: .off, textFocus: .off, windowSwitch: .needsPermission
        )
        #expect(state.onAppSwitch == .switchToDefault)
        #expect(state.onWindowSwitch == .restoreLast)
        #expect(state.showsWindowSwitchPermissionItem)
        #expect(state.showsForgetItem)

        let noRestore = StatusMenuState(settings: settings(app: .switchToDefault, window: .keep), enabledSources: [.abc], escape: .off, textFocus: .off)
        #expect(!noRestore.showsForgetItem) // 복원을 고르지 않으면 "지우기"는 숨긴다
        #expect(StatusMenuState(settings: settings(app: .restoreLast, window: .keep), enabledSources: [.abc], escape: .off, textFocus: .off).showsForgetItem)
    }

    @MainActor
    @Test func persists() {
        let defaults = makeTestDefaults()
        #expect(SettingsStore(defaults: defaults).settings.onAppSwitch == .keep)
        #expect(defaults.object(forKey: "onAppSwitch") == nil) // 기본값은 저장하지 않는다
        SettingsStore(defaults: defaults).update {
            $0.onAppSwitch = .restoreLast
            $0.onWindowSwitch = .restoreLast
        }
        #expect(defaults.string(forKey: "onAppSwitch") == "restoreLast")
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.onAppSwitch == .restoreLast)
        #expect(reloaded.onWindowSwitch == .restoreLast)
    }

    struct OldSettings: Sendable, CustomTestStringConvertible {
        var values: [String: String]
        var app: SwitchBehavior
        var window: SwitchBehavior
        var testDescription: String { values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") }
    }

    @MainActor
    @Test(arguments: [
        OldSettings(values: [:], app: .keep, window: .keep),
        OldSettings(values: ["rememberInputPerApp": "1"], app: .restoreLast, window: .keep),
        OldSettings(values: ["rememberInputPerApp": "1", "resetOnAppSwitch": "1"], app: .restoreLast, window: .keep),
        OldSettings(values: ["resetOnAppSwitch": "1"], app: .switchToDefault, window: .keep),
        OldSettings(values: ["resetOnWindowSwitch": "1"], app: .keep, window: .switchToDefault),
        OldSettings(values: ["rememberInputPerApp": "1", "resetOnWindowSwitch": "1"], app: .restoreLast, window: .switchToDefault),
        OldSettings(values: ["rememberInputPerWindow": "1"], app: .restoreLast, window: .restoreLast),
        OldSettings(values: ["inputMemory": "perApp", "resetOnWindowSwitch": "1"], app: .restoreLast, window: .switchToDefault),
        OldSettings(values: ["inputMemory": "perWindow"], app: .restoreLast, window: .restoreLast)
    ])
    func migratesOldSettings(_ old: OldSettings) {
        // 앱·창 전환이 토글과 기억 옵션으로 나뉘어 있던 때의 값을 옮기고, 옛 키는 지운다
        let defaults = makeTestDefaults()
        for (key, value) in old.values {
            if key == "inputMemory" { defaults.set(value, forKey: key) } else { defaults.set(value == "1", forKey: key) }
        }
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.onAppSwitch == old.app)
        #expect(store.settings.onWindowSwitch == old.window)
        for key in ["resetOnAppSwitch", "resetOnWindowSwitch", "rememberInputPerApp", "rememberInputPerWindow", "inputMemory"] {
            #expect(defaults.object(forKey: key) == nil)
        }
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.onAppSwitch == old.app)
        #expect(reloaded.onWindowSwitch == old.window)
    }

    @Test func trackerExposesTheCurrentWindow() {
        var tracker = WindowSwitchTracker<Int>()
        #expect(tracker.currentWindow == nil)
        tracker.reset(to: 1)
        _ = tracker.mainWindowChanged(to: 2)
        #expect(tracker.currentWindow == 2)
        _ = tracker.mainWindowChanged(to: nil) // 창이 잠깐 없어도 기준은 유지
        #expect(tracker.currentWindow == 2)
    }
}

/// 실제 흐름(앱·창 모두 "마지막 입력 소스로 복원"): 창 A에서 한국어 → 창 B(처음, ABC) → 창 A로 돌아오면 한국어.
@MainActor
@Suite("Window memory flow")
struct WindowMemoryFlowTests {
    @MainActor
    private final class Harness {
        var settings = KeyHueSettings()
        let switcher: FakeSwitcher
        let clock = FakeScheduler()
        lazy var coordinator = AutoResetCoordinator(
            switcher: switcher, scheduler: clock,
            memory: AppInputMemory(defaults: makeTestDefaults())
        ) { [unowned self] in self.settings }

        init(current: InputSourceInfo, configure: (inout KeyHueSettings) -> Void) {
            switcher = FakeSwitcher(current: current)
            settings.onAppSwitch = .restoreLast
            settings.onWindowSwitch = .restoreLast
            configure(&settings)
        }

        /// 사용자가 직접 바꿨다(입력 소스 알림).
        func userSelects(_ source: InputSourceInfo, in window: Int) {
            let old = switcher.currentSource
            switcher.currentSource = source
            coordinator.sourceChanged(from: old, to: source, activeBundleID: "com.apple.Terminal", activeWindow: window)
        }

        func switchWindow(from previous: Int?, to window: Int) {
            coordinator.windowSwitched(from: previous, to: window, current: switcher.currentSource)
            clock.advance(by: AutoResetCoordinator.appSwitchSettleDelay + AutoResetCoordinator.verifyDelay)
        }
    }

    @Test func restoresEachWindowsSource() {
        let h = Harness(current: .abc) { _ in }
        h.userSelects(.korean2Set, in: 1)
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .abc) // 처음 보는 창 → 기본 입력 소스
        h.userSelects(.hiragana, in: 2)
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .korean2Set) // 기억한 창 → 되살림
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .hiragana)
    }

    @Test func windowOptionWorksWithTheAppOptionOff() {
        // "앱을 바꿀 때"는 그대로 두기, "창을 바꿀 때"만 복원: 같은 앱의 창끼리는 복원하고, 앱 전환에는 손대지 않는다
        let h = Harness(current: .abc) { $0.onAppSwitch = .keep }
        h.userSelects(.korean2Set, in: 1)
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .abc) // 처음 보는 창 → 기본 입력 소스
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .korean2Set) // 기억한 창 → 되살림

        // 다른 앱으로 갔다가 창 2가 앞인 채로 돌아와도, 앱 전환은 "그대로 두기"라 바꾸지 않는다
        h.coordinator.appActivated(previousBundleID: "com.apple.Terminal", currentBundleID: "com.apple.Safari",
                                   sourceBeforeActivation: .korean2Set, previousWindow: 1)
        h.coordinator.appActivated(previousBundleID: "com.apple.Safari", currentBundleID: "com.apple.Terminal",
                                   sourceBeforeActivation: .korean2Set, currentWindow: { 2 })
        h.clock.advance(by: AutoResetCoordinator.appSwitchSettleDelay + AutoResetCoordinator.verifyDelay)
        #expect(h.switcher.currentSource == .korean2Set)

        // 돌아온 창 2에서 한국어로 있었으므로, 창 2의 기억은 한국어로 바뀐다(마지막으로 쓴 입력 소스)
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .korean2Set) // 창 1의 기억도 한국어
        h.userSelects(.hiragana, in: 1)
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .korean2Set)
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .hiragana)
    }

    @Test func leavingAWindowRecordsItsSourceEvenWithoutChanges() {
        // 창 1에서 한 번도 바꾸지 않았어도, 떠날 때의 입력 소스를 창 1 몫으로 기록한다
        let h = Harness(current: .hiragana) { _ in }
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .abc)
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .hiragana)
    }

    @Test func waitsForTheSettleDelay() {
        let h = Harness(current: .abc) { _ in }
        h.userSelects(.korean2Set, in: 1)
        h.userSelects(.abc, in: 2)
        h.coordinator.windowSwitched(from: 2, to: 1, current: .abc)
        h.clock.advance(by: AutoResetCoordinator.appSwitchSettleDelay - 0.01)
        #expect(h.switcher.currentSource == .abc)
        h.clock.advance(by: 0.01)
        #expect(h.switcher.currentSource == .korean2Set)
    }

    @Test func appActivationRestoresTheFrontWindowFirst() {
        let h = Harness(current: .abc) { _ in }
        h.userSelects(.korean2Set, in: 1)
        h.userSelects(.hiragana, in: 2) // 앱 기억은 마지막 값(히라가나)
        // 다른 앱으로 갔다가, 창 1이 앞에 있는 상태로 돌아온다
        h.coordinator.appActivated(previousBundleID: "com.apple.Terminal", currentBundleID: "com.apple.Safari",
                                   sourceBeforeActivation: .hiragana, previousWindow: 2,
                                   currentWindow: { nil })
        h.clock.advance(by: 1)
        h.switcher.currentSource = .abc
        h.coordinator.appActivated(previousBundleID: "com.apple.Safari", currentBundleID: "com.apple.Terminal",
                                   sourceBeforeActivation: .abc, previousWindow: nil,
                                   currentWindow: { 1 })
        h.clock.advance(by: 1)
        #expect(h.switcher.currentSource == .korean2Set)
    }

    @Test func unknownFrontWindowFallsBackToTheAppsSource() {
        // KeyHue를 다시 실행했거나 새 창이 앞에 있을 때: 앱별 기억으로 보완한다
        let h = Harness(current: .abc) { _ in }
        h.userSelects(.hiragana, in: 1)
        h.coordinator.appActivated(previousBundleID: "com.apple.Terminal", currentBundleID: "com.apple.Safari",
                                   sourceBeforeActivation: .hiragana, previousWindow: 1,
                                   currentWindow: { nil })
        h.clock.advance(by: 1)
        h.switcher.currentSource = .abc
        h.coordinator.appActivated(previousBundleID: "com.apple.Safari", currentBundleID: "com.apple.Terminal",
                                   sourceBeforeActivation: .abc, previousWindow: nil,
                                   currentWindow: { 99 })
        h.clock.advance(by: 1)
        #expect(h.switcher.currentSource == .hiragana)
    }

    @Test func newWindowInTheSameAppStartsWithTheDefault() {
        // 같은 앱 안의 새 창(⌘N)은 앱별 기억을 쓰지 않고 기본 입력 소스로 시작한다
        let h = Harness(current: .abc) { _ in }
        h.userSelects(.korean2Set, in: 1)
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func appRestoreWithWindowSwitchToDefault() {
        // 앱은 복원, 창은 ABC: 앱으로 돌아오면 앱의 마지막 입력 소스, 창을 바꾸면 ABC
        let h = Harness(current: .abc) { $0.onWindowSwitch = .switchToDefault }
        h.userSelects(.korean2Set, in: 1)
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "com.apple.Terminal")
        h.switchWindow(from: 1, to: 2)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.coordinator.windowMemory.count == 0)
        // 실제 앱에서는 KeyHue가 바꾼 것도 입력 소스 알림으로 들어와 앱 몫으로 기록된다
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: "com.apple.Terminal")
        h.switcher.currentSource = .hiragana
        h.coordinator.appActivated(previousBundleID: "com.apple.Safari", currentBundleID: "com.apple.Terminal",
                                   sourceBeforeActivation: .hiragana, currentWindow: { 1 })
        h.clock.advance(by: 1)
        #expect(h.switcher.currentSource == .abc) // 창 2에서 ABC로 바뀐 게 앱의 마지막 입력 소스
    }

    @Test func keepingWindowsDoesNotRecordOrRestoreThem() {
        let h = Harness(current: .abc) { $0.onWindowSwitch = .keep }
        h.userSelects(.korean2Set, in: 1)
        h.switchWindow(from: 1, to: 2)
        h.userSelects(.abc, in: 2)
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.coordinator.windowMemory.count == 0)
    }

    @Test func forgetClearsWindowMemory() {
        let h = Harness(current: .abc) { _ in }
        h.userSelects(.korean2Set, in: 1)
        h.coordinator.forgetRememberedInputs()
        #expect(h.coordinator.windowMemory.count == 0)
        h.switchWindow(from: 2, to: 1)
        #expect(h.switcher.currentSource == .abc) // 창 1 기록이 지워져 처음 보는 창처럼 기본 입력 소스
        #expect(h.coordinator.windowMemory.source(for: 1) == nil)
    }
}

@Suite("Window input memory edge cases")
struct WindowInputMemoryEdgeCaseTests {
    @Test func rerecordingAKnownWindowAtCapacityEvictsNothing() {
        var memory = WindowInputMemory<Int>()
        let capacity = WindowInputMemory<Int>.capacity
        for window in 0..<capacity {
            memory.record(sourceID: "s\(window)", for: window)
        }
        memory.record(sourceID: "changed", for: 0)
        memory.record(sourceID: "same", for: 50)
        #expect(memory.count == capacity)
        #expect((0..<capacity).allSatisfy { memory.source(for: $0) != nil })
        #expect(memory.source(for: 0) == "changed")
    }

    @Test func manyClosedWindowsStayBoundedAndKeepTheMostRecent() {
        // 창을 계속 열고 닫아도(새 AX 요소) 최근 창만 남는다
        var memory = WindowInputMemory<Int>()
        let capacity = WindowInputMemory<Int>.capacity
        for window in 0..<(capacity * 3) {
            memory.record(sourceID: "s\(window)", for: window)
        }
        #expect(memory.count == capacity)
        #expect(memory.source(for: capacity * 2 - 1) == nil)
        #expect(memory.source(for: capacity * 2) == "s\(capacity * 2)")
        #expect(memory.source(for: capacity * 3 - 1) == "s\(capacity * 3 - 1)")
    }

    @Test func recordingAfterClearStartsFresh() {
        var memory = WindowInputMemory<Int>()
        for window in 0..<WindowInputMemory<Int>.capacity {
            memory.record(sourceID: "old", for: window)
        }
        memory.clear()
        memory.record(sourceID: "new", for: 1)
        #expect(memory.count == 1)
        #expect(memory.source(for: 0) == nil)
        #expect(memory.source(for: 1) == "new")
    }
}
