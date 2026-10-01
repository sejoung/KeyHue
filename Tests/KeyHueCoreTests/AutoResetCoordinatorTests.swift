import Foundation
import Testing
@testable import KeyHueCore

/// 가짜 입력 소스 전환기: 전환하면 목표 Source가 현재 Source가 된다.
@MainActor
final class FakeSwitcher: InputSourceSwitching {
    var currentSource: InputSourceInfo?
    private(set) var performed: [InputSourceAction] = []
    var known: [InputSourceInfo] = [.abc, .us, .german, .korean2Set, .hiragana]
    var availableSources: [InputSourceInfo] { known }
    var shouldSucceed = true

    init(current: InputSourceInfo?) {
        currentSource = current
    }

    func perform(_ action: InputSourceAction) -> Bool {
        performed.append(action)
        guard shouldSucceed else { return false }
        switch action {
        case .none:
            return false
        case .selectDefault(let preferredID):
            guard let target = DefaultInputSourcePicker.pick(from: known, preferredID: preferredID) else { return false }
            currentSource = target
        case .select(let id):
            guard let match = known.first(where: { $0.id == id }) else { return false }
            currentSource = match
        }
        return true
    }
}

/// 가짜 시간: advance(by:)로 흘린 만큼 예약된 작업을 순서대로 실행한다.
@MainActor
final class FakeScheduler: Scheduling {
    private var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, work: @MainActor () -> Void)] = []
    private var counter = 0

    var pendingCount: Int { pending.count }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        counter += 1
        pending.append((now + delay, counter, work))
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = pending.filter({ $0.at <= target + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = next.at
            next.work()
        }
        now = target
    }
}

@MainActor
private final class Harness {
    var settings = KeyHueSettings()
    let switcher: FakeSwitcher
    let scheduler = FakeScheduler()
    let memory = AppInputMemory(defaults: makeTestDefaults())
    var events: [AutoResetCoordinator.Event] = []
    lazy var coordinator: AutoResetCoordinator = {
        let coordinator = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: memory) { [unowned self] in self.settings }
        coordinator.onEvent = { [unowned self] in self.events.append($0) }
        return coordinator
    }()

    init(current: InputSourceInfo?, configure: (inout KeyHueSettings) -> Void = { _ in }) {
        switcher = FakeSwitcher(current: current)
        configure(&settings)
    }

    func activate(_ bundleID: String, from previous: String? = nil) {
        coordinator.appActivated(
            previousBundleID: previous,
            currentBundleID: bundleID,
            sourceBeforeActivation: switcher.currentSource
        )
    }
}

@MainActor
@Suite("AutoResetCoordinator")
struct AutoResetCoordinatorTests {
    @Test func deletedAppMemoryFallsBackAndVerifiesTheFallback() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.memory.record(sourceID: "removed", for: "target.app")
        h.activate("target.app")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.selectDefault(preferredID: nil)])

        // 시스템이 전환을 덮어쓰더라도 삭제된 기억 대신 실제 대체 동작을 재시도한다.
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "target.app")
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.selectDefault(preferredID: nil), .selectDefault(preferredID: nil)])
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func deletedWindowMemoryUsesConfiguredDefault() {
        let h = Harness(current: .korean2Set) {
            $0.onWindowSwitch = .restoreLast
            $0.defaultSourceID = InputSourceInfo.hiragana.id
        }
        h.coordinator.sourceChanged(from: nil, to: .german, activeBundleID: nil, activeWindow: 2)
        h.switcher.known.removeAll { $0.id == InputSourceInfo.german.id }
        h.coordinator.windowSwitched(to: 2, current: .korean2Set)
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .hiragana)
        #expect(h.switcher.performed == [.selectDefault(preferredID: InputSourceInfo.hiragana.id)])
    }

    @Test func deletedFrontWindowMemoryFallsBackToAvailableAppMemory() {
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .restoreLast
            $0.onWindowSwitch = .restoreLast
        }
        h.memory.record(sourceID: InputSourceInfo.hiragana.id, for: "target.app")
        h.coordinator.sourceChanged(from: nil, to: .german, activeBundleID: nil, activeWindow: 2)
        h.switcher.known.removeAll { $0.id == InputSourceInfo.german.id }
        h.coordinator.appActivated(
            previousBundleID: nil, currentBundleID: "target.app", sourceBeforeActivation: .korean2Set,
            currentWindow: { 2 }
        )
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .hiragana)
        #expect(h.switcher.performed == [.select(sourceID: InputSourceInfo.hiragana.id)])
    }

    @Test func defaultDeletedWhileSwitchIsPendingFallsBackOnce() {
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .switchToDefault
            $0.defaultSourceID = InputSourceInfo.german.id
        }
        h.activate("target.app")
        h.switcher.known.removeAll { $0.id == InputSourceInfo.german.id }
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [.selectDefault(preferredID: nil)])
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test(arguments: [[], [InputSourceInfo.korean2Set, .hiragana]])
    func noAvailableFallbackLeavesCurrentInputAndDoesNotRetry(_ sources: [InputSourceInfo]) {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.switcher.known = sources
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.scheduler.pendingCount == 0)
        #expect(h.events == [.skipped(.selectDefault(preferredID: nil))])
    }

    @Test func failedSwitchDoesNotWatchOrRetryAnUnchangedInput() {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.switcher.shouldSucceed = false
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.count == 1)
        #expect(h.scheduler.pendingCount == 0)
        #expect(h.events == [.switched(.selectDefault(preferredID: nil), ok: false)])
    }

    @Test func failedNewSwitchCancelsVerificationOfThePreviousTarget() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("first.app")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)

        h.settings.defaultSourceID = InputSourceInfo.hiragana.id
        h.switcher.shouldSucceed = false
        h.activate("second.app")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "second.app")
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed == [.selectDefault(preferredID: nil), .selectDefault(preferredID: InputSourceInfo.hiragana.id)])
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func escapeSwitchesOnNextRunLoop() {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: h.switcher.currentSource)
        #expect(h.switcher.performed.isEmpty) // 이벤트 처리 중에는 바꾸지 않는다
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.events == [.switched(.selectDefault(preferredID: nil), ok: true)])
    }

    @Test func appSwitchWaitsForActivationToSettle() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("com.apple.Terminal")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay - 0.01)
        #expect(h.switcher.performed.isEmpty)
        h.scheduler.advance(by: 0.01)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func skipsWhenUserAlreadySwitchedWhileWaiting() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("com.apple.Terminal")
        h.switcher.currentSource = .abc // 대기 중 사용자가 직접 바꿈
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        // 앱 전환은 전환 시점에 판단하므로 할 일이 없으면 이벤트도 없다(ESC·창 전환은 .skipped를 남긴다)
        #expect(h.events.isEmpty)
    }

    @Test func escapeSkipsWhenUserAlreadySwitchedWhileWaiting() {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.switcher.currentSource = .abc
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.events == [.skipped(.selectDefault(preferredID: nil))])
    }

    /// 실측한 경쟁 상태: 전환 직후 시스템이 새 앱에 이전 Source를 다시 적용한다(ADR 0007).
    /// 알림을 놓친 경우: 지켜보는 시간 끝의 마지막 확인에서 한 번만 다시 바꾼다.
    @Test func retriesOnceWhenSystemOverridesTheSwitch() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("com.google.Chrome")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)

        h.switcher.currentSource = .korean2Set // 덮어써짐
        h.scheduler.advance(by: AutoResetCoordinator.verifyDelay)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed.count == 2)

        h.switcher.currentSource = .korean2Set // 또 덮어써져도 더 이상 재시도하지 않는다
        h.scheduler.advance(by: 10)
        #expect(h.switcher.performed.count == 2)
        #expect(h.events == [
            .switched(.selectDefault(preferredID: nil), ok: true),
            .retrying(.selectDefault(preferredID: nil)),
            .switched(.selectDefault(preferredID: nil), ok: true)
        ])
    }

    @Test func noRetryWhenSwitchSticks() {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.scheduler.advance(by: 10)
        #expect(h.switcher.performed.count == 1)
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func nothingScheduledWhenPolicySaysNone() {
        let h = Harness(current: .abc) { $0.resetOnEscape = true }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .abc)
        #expect(h.scheduler.pendingCount == 0)
        h.coordinator.keyDown(keyCode: 0, isAutoRepeat: false, current: .korean2Set)
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func textFieldExitSwitches() {
        let h = Harness(current: .korean2Set) { $0.resetOnTextFocusLoss = true }
        h.coordinator.focusChanged(wasTextInput: true, isTextInput: false, current: .korean2Set)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func explicitDefaultSourceIsUsed() {
        let h = Harness(current: .abc) {
            $0.resetOnEscape = true
            $0.defaultSourceID = InputSourceInfo.german.id
        }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .german)
    }

    // MARK: 앱별 기억

    @Test func remembersPreviousAppAndRestoresOnReturn() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.activate("com.apple.Terminal", from: "com.tinyspeck.slackmacgap") // Slack을 한국어로 두고 떠남
        #expect(h.memory.entries["com.tinyspeck.slackmacgap"] == InputSourceInfo.korean2Set.id)

        h.switcher.currentSource = .abc
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: "com.apple.Terminal")
        #expect(h.memory.entries["com.apple.Terminal"] == InputSourceInfo.abc.id)

        h.activate("com.tinyspeck.slackmacgap", from: "com.apple.Terminal")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .korean2Set)
    }

    @Test func rememberedSourceBeatsResetToDefault() {
        // 복원을 골랐으면 기록이 있는 앱은 기본 입력 소스 대신 기록을 되살린다
        let h = Harness(current: .abc) {
            $0.onAppSwitch = .restoreLast
        }
        h.memory.record(sourceID: InputSourceInfo.korean2Set.id, for: "notion")
        h.activate("notion")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .korean2Set)
    }

    @Test func doesNotRecordWhenMemoryIsOff() {
        let h = Harness(current: .korean2Set)
        h.activate("b", from: "a")
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: "b")
        #expect(h.memory.entries.isEmpty)
    }

    @Test func sourceChangeWithoutActiveAppOrSameSourceIsIgnored() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: nil)
        h.coordinator.sourceChanged(from: .abc, to: .abc, activeBundleID: "a")
        #expect(h.memory.entries.isEmpty)
    }

    @Test func decidesWithTheActualSourceAtSwitchTime() {
        // 알림을 놓쳐 저장된 값은 한국어였지만, 전환 시점에 실제로는 이미 ABC → 아무것도 하지 않는다.
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.coordinator.appActivated(previousBundleID: nil, currentBundleID: "x", sourceBeforeActivation: .korean2Set)
        h.switcher.currentSource = .abc
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.events.isEmpty)
    }

    // MARK: 앱 전환 지연 (ADR 0031)

    @Test func settleDelayStaysWithinTheMeasuredSafeRange() {
        // 실측: 활성화 후 20 ms 이상이면 덮어쓰기 0/88. 너무 줄이면 깜빡이고, 늘리면 굼뜨다
        #expect(AutoResetCoordinator.appSwitchSettleDelay >= 0.02)
        #expect(AutoResetCoordinator.appSwitchSettleDelay <= 0.05)
    }

    @Test func overrideNotificationRetriesRightAway() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("com.google.Chrome")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: "com.google.Chrome") // 자기 전환 알림: 그대로

        // 시스템이 한국어로 되돌렸다는 알림 → 마지막 확인을 기다리지 않고 다음 차례에 다시 바꾼다
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "com.google.Chrome")
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed.count == 2)

        // 마지막 확인은 이미 처리했으므로 더 바꾸지 않는다
        h.scheduler.advance(by: 10)
        #expect(h.switcher.performed.count == 2)
        #expect(h.events == [
            .switched(.selectDefault(preferredID: nil), ok: true),
            .retrying(.selectDefault(preferredID: nil)),
            .switched(.selectDefault(preferredID: nil), ok: true)
        ])
    }

    @Test func overriddenSourceIsNotRemembered() {
        let h = Harness(current: .abc) { $0.onAppSwitch = .restoreLast }
        h.memory.record(sourceID: InputSourceInfo.korean2Set.id, for: "notion")
        h.activate("notion")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .korean2Set)
        h.switcher.currentSource = .abc
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: "notion") // 시스템이 되돌림
        #expect(h.memory.entries["notion"] == InputSourceInfo.korean2Set.id)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .korean2Set)
    }

    @Test func changesAfterTheWatchWindowAreLeftAlone() {
        // 지켜보는 시간이 지난 뒤의 변경은 사용자의 선택이므로 되돌리지 않는다
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("com.apple.Terminal")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay + AutoResetCoordinator.verifyDelay)
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "com.apple.Terminal")
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.count == 1)
    }

    // MARK: 사용자가 직접 바꾼 것은 되돌리지 않는다 (ADR 0037)

    @Test func watchWindowIsShortEnoughNotToFightTheUser() {
        // 시스템 덮어쓰기 알림은 활성화 후 12–36 ms(실측, 전환은 40 ms). 사람이 새 앱을 보고 한/영을 누르기엔 짧아야 한다
        #expect(AutoResetCoordinator.verifyDelay >= 0.05)
        #expect(AutoResetCoordinator.verifyDelay <= 0.1)
    }

    @Test func manualSwitchRightAfterAnAppSwitchIsKept() {
        // ⌘Tab 직후 ⌘Space: 자동 전환 0.15초 뒤 사용자가 한국어로 바꿨다 → 그대로 둔다
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("com.apple.Terminal")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)
        h.scheduler.advance(by: 0.15)
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "com.apple.Terminal")
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.count == 1)
    }

    @Test func typingStopsWatchingTheAutoSwitch() {
        // 지켜보는 중이라도 키 입력이 있으면(ESC 감지가 켜져 있을 때) 이후 변경은 사용자의 선택으로 본다
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .switchToDefault
            $0.resetOnEscape = true
        }
        h.activate("com.apple.Terminal")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        h.coordinator.keyDown(keyCode: 49, isAutoRepeat: false, current: .abc) // ⌘Space
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "com.apple.Terminal")
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.count == 1)
    }

    @Test func overwriteWithoutTypingIsStillCorrected() {
        // 키 입력 없이 곧바로 되돌려진 것은 여전히 시스템 덮어쓰기로 보고 바로잡는다
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .switchToDefault
            $0.resetOnEscape = true
        }
        h.activate("com.apple.Terminal")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "com.apple.Terminal")
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func frontWindowIsReadAtSwitchTime() {
        // 앱에 붙는 작업(AX)은 전환 예약 뒤에 하므로, 앞 창은 전환 시점에 읽어야 한다
        let h = Harness(current: .abc) {
            $0.onAppSwitch = .restoreLast
            $0.onWindowSwitch = .restoreLast
        }
        h.coordinator.windowSwitched(from: 7, to: 8, current: .abc)
        h.switcher.currentSource = .hiragana
        h.coordinator.sourceChanged(from: .abc, to: .hiragana, activeBundleID: "com.apple.Terminal", activeWindow: 8)
        h.scheduler.advance(by: 1)

        h.switcher.currentSource = .abc
        var frontWindow: AnyHashable?
        h.coordinator.appActivated(previousBundleID: "com.apple.Safari", currentBundleID: "com.apple.Terminal",
                                   sourceBeforeActivation: .abc, currentWindow: { frontWindow })
        frontWindow = 8 // 호출 뒤에 붙어서 알게 됨
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .hiragana)
    }
}


/// 코드 검토에서 찾은 앱 전환 대기(40 ms) 중의 경쟁 상태(회귀 방지).
@MainActor
@Suite("Auto reset while an app switch is settling")
struct AutoResetSettlingTests {
    @Test func appFrontForLessThanTheSettleDelayKeepsItsMemory() {
        // A → B → C가 40 ms 안에 일어나면 B의 전환은 일어나지 않았다. A의 입력 소스를 B 몫으로 기록하면 안 된다
        var settings = KeyHueSettings()
        settings.onAppSwitch = .restoreLast
        let switcher = FakeSwitcher(current: .korean2Set)
        let scheduler = FakeScheduler()
        let memory = AppInputMemory(defaults: makeTestDefaults())
        let c = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: memory) { settings }
        memory.record(sourceID: InputSourceInfo.hiragana.id, for: "B")
        memory.record(sourceID: InputSourceInfo.abc.id, for: "C")
        c.appActivated(previousBundleID: "A", currentBundleID: "B", sourceBeforeActivation: switcher.currentSource)
        scheduler.advance(by: 0.01)
        c.appActivated(previousBundleID: "B", currentBundleID: "C", sourceBeforeActivation: switcher.currentSource)
        scheduler.advance(by: 1)
        #expect(switcher.currentSource == .abc)                          // C의 기억
        #expect(memory.entries["B"] == InputSourceInfo.hiragana.id)      // B의 기억은 그대로
        #expect(memory.entries["A"] == InputSourceInfo.korean2Set.id)
    }

    @Test func windowSwitchWhileSettlingFollowsTheAppDecision() {
        // 뒤에 있던 앱의 다른 창을 눌러 활성화하면 40 ms 안에 메인 창 변경이 온다. 이것은 앱 전환의 일부다
        var settings = KeyHueSettings()
        settings.onAppSwitch = .restoreLast
        settings.onWindowSwitch = .restoreLast
        let switcher = FakeSwitcher(current: .korean2Set)
        let scheduler = FakeScheduler()
        let memory = AppInputMemory(defaults: makeTestDefaults())
        let c = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: memory) { settings }
        memory.record(sourceID: InputSourceInfo.hiragana.id, for: "B")
        var front: AnyHashable? = 1
        c.appActivated(previousBundleID: "A", currentBundleID: "B", sourceBeforeActivation: .korean2Set, currentWindow: { front })
        scheduler.advance(by: 0.02)
        front = 2
        c.windowSwitched(from: 1, to: 2, current: switcher.currentSource) // 아직 A의 한국어
        scheduler.advance(by: 1)
        #expect(c.windowMemory.source(for: 1) == nil)                    // A의 입력 소스를 B의 창 1 몫으로 기록하지 않는다
        #expect(switcher.currentSource == .hiragana)                     // B의 기억이 늦게 온 창 전환에 덮이지 않는다
    }

    @Test func windowSwitchAfterSettlingStillWorks() {
        var settings = KeyHueSettings()
        settings.onWindowSwitch = .switchToDefault
        let switcher = FakeSwitcher(current: .korean2Set)
        let scheduler = FakeScheduler()
        let c = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: AppInputMemory(defaults: makeTestDefaults())) { settings }
        c.appActivated(previousBundleID: "A", currentBundleID: "B", sourceBeforeActivation: .korean2Set)
        scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay + 0.01)
        c.windowSwitched(from: 1, to: 2, current: switcher.currentSource)
        scheduler.advance(by: 1)
        #expect(switcher.currentSource == .abc)
    }
}
