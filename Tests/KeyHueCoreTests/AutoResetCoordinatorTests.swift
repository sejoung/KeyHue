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
    var failingSourceIDs: Set<String> = []

    init(current: InputSourceInfo?) {
        currentSource = current
    }

    func perform(_ action: InputSourceAction) -> Bool {
        performed.append(action)
        guard shouldSucceed else { return false }
        switch action {
        case .select(let id) where failingSourceIDs.contains(id): return false
        case .selectDefault(let id?) where failingSourceIDs.contains(id): return false
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

private extension Harness {
    /// 창 기억을 미리 채운다(지금 옵션과 관계없이, 앱 기억은 건드리지 않는다).
    func rememberWindow(_ window: Int, _ source: InputSourceInfo) {
        let saved = settings
        settings.onAppSwitch = .keep
        settings.onWindowSwitch = .restoreLast
        coordinator.sourceChanged(from: nil, to: source, activeBundleID: nil, activeWindow: window)
        settings = saved
    }
}

/// 자동 전환 코어 감사에서 추가한 엣지 케이스.
@MainActor
@Suite("Auto reset edge cases")
struct AutoResetEdgeCaseTests {
    // MARK: 빠른 연속 전환 (ADR 0043)

    @Test func supersededActivationNeverSwitchesEvenBriefly() {
        // A → B → C가 40 ms 안에: B의 예약된 전환은 한 번도 실행되지 않는다(깜빡임 없음)
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.memory.record(sourceID: InputSourceInfo.hiragana.id, for: "B")
        h.memory.record(sourceID: InputSourceInfo.german.id, for: "C")
        h.activate("B", from: "A")
        h.scheduler.advance(by: 0.01)
        h.activate("C", from: "B")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed == [.select(sourceID: InputSourceInfo.german.id)])
        #expect(h.switcher.currentSource == .german)
    }

    @Test func bouncingBackWithinTheSettleDelayLeavesEverythingAsItWas() {
        // A → B → A가 40 ms 안에: B의 전환은 취소되고, A는 이미 자기 Source라 아무것도 하지 않는다
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.memory.record(sourceID: InputSourceInfo.hiragana.id, for: "B")
        h.activate("B", from: "A")
        h.scheduler.advance(by: 0.01)
        h.activate("A", from: "B")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.events.isEmpty)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.memory.entries == ["A": InputSourceInfo.korean2Set.id, "B": InputSourceInfo.hiragana.id])
    }

    @Test func windowLeftBeforeItsAppSettledIsNotRecorded() {
        // A(창 1) → B(창 2) → C가 40 ms 안에: B의 창 2에는 A의 Source를 남기지 않는다
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .restoreLast
            $0.onWindowSwitch = .restoreLast
        }
        h.coordinator.appActivated(previousBundleID: "A", currentBundleID: "B", sourceBeforeActivation: .korean2Set,
                                   previousWindow: 1, currentWindow: { 2 })
        h.scheduler.advance(by: 0.01)
        h.coordinator.appActivated(previousBundleID: "B", currentBundleID: "C", sourceBeforeActivation: .korean2Set,
                                   previousWindow: 2, currentWindow: { 3 })
        h.scheduler.advance(by: 1)
        #expect(h.coordinator.windowMemory.source(for: 1) == InputSourceInfo.korean2Set.id)
        #expect(h.coordinator.windowMemory.source(for: 2) == nil)
        #expect(h.switcher.currentSource == .abc) // C와 창 3은 처음 → 기본 입력 소스
    }

    @Test func windowFrontForLessThanTheSettleDelayKeepsItsMemory() {
        // 창 1 → 2 → 3이 40 ms 안에(⌘` 연타): 앱의 A → B → C와 같다.
        // 창 2의 전환은 일어나지 않았으므로 창 1의 Source를 창 2 몫으로 기록하거나, 창 3이 앞일 때 창 2의 Source로 바꾸면 안 된다
        let h = Harness(current: .korean2Set) { $0.onWindowSwitch = .restoreLast }
        h.rememberWindow(2, .hiragana)
        h.rememberWindow(3, .german)
        h.coordinator.windowSwitched(from: 1, to: 2, current: .korean2Set)
        h.scheduler.advance(by: 0.01)
        h.coordinator.windowSwitched(from: 2, to: 3, current: .korean2Set)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .german)
        #expect(h.switcher.performed == [.select(sourceID: InputSourceInfo.german.id)])
        #expect(h.coordinator.windowMemory.source(for: 2) == InputSourceInfo.hiragana.id)
    }

    @Test func appSwitchRightAfterAWindowSwitchKeepsThatWindowsMemory() {
        // 창 1 → 창 2로 바꾸자마자(40 ms 안) 다른 앱으로 갔다: 창 2의 전환은 일어나지 않았으므로
        // 떠날 때의 Source(창 1의 것)를 창 2 몫으로 기록하면 안 된다(앱의 A → B → C와 같은 경우)
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .restoreLast
            $0.onWindowSwitch = .restoreLast
        }
        h.rememberWindow(2, .hiragana)
        h.memory.record(sourceID: InputSourceInfo.german.id, for: "B")
        h.coordinator.windowSwitched(from: 1, to: 2, current: .korean2Set)
        h.scheduler.advance(by: 0.01)
        h.coordinator.appActivated(previousBundleID: "A", currentBundleID: "B", sourceBeforeActivation: .korean2Set,
                                   previousWindow: 2, currentWindow: { 9 })
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .german)
        #expect(h.switcher.performed == [.select(sourceID: InputSourceInfo.german.id)])
        #expect(h.coordinator.windowMemory.source(for: 2) == InputSourceInfo.hiragana.id)
    }

    @Test func appSwitchRightAfterAWindowSwitchDoesNotRunTheStaleWindowSwitch() {
        // 앱은 복원, 창은 기본 입력 소스로: 창을 바꾸자마자(40 ms 안) 다른 앱 B로 갔다.
        // 앞 앱 창의 예약된 전환이 B가 앞일 때 실행되면, 그 알림이 B 몫으로 기록돼 B의 복원(German)까지 바뀐다
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .restoreLast
            $0.onWindowSwitch = .switchToDefault
        }
        h.memory.record(sourceID: InputSourceInfo.german.id, for: "B")
        h.coordinator.windowSwitched(from: 1, to: 2, current: .korean2Set)  // t = 0, 창 전환 예약 40 ms
        h.scheduler.advance(by: 0.01)
        h.activate("B", from: "A")                                           // t = 10 ms, 앱 전환 예약 50 ms
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay - 0.01) // t = 40 ms
        // 실제 앱에서는 KeyHue가 바꾼 것도 입력 소스 알림으로 들어와 그때의 활성 앱(B) 몫으로 기록된다
        h.coordinator.sourceChanged(from: .korean2Set, to: h.switcher.currentSource, activeBundleID: "B")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed == [.select(sourceID: InputSourceInfo.german.id)])
        #expect(h.switcher.currentSource == .german)
    }

    // MARK: Bundle ID가 없는 앱

    @Test func appsWithoutBundleIDAreNeitherRecordedNorRestored() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.memory.record(sourceID: InputSourceInfo.hiragana.id, for: "known")
        h.coordinator.appActivated(previousBundleID: nil, currentBundleID: nil, sourceBeforeActivation: .korean2Set)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc) // 기록을 찾을 수 없다 → 처음 가는 앱처럼 기본 입력 소스

        h.coordinator.appActivated(previousBundleID: nil, currentBundleID: "known", sourceBeforeActivation: .abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .hiragana)
        #expect(h.memory.entries == ["known": InputSourceInfo.hiragana.id])
    }

    // MARK: 옵션 조합 (ADR 0029)

    @Test(arguments: SwitchBehavior.allCases, SwitchBehavior.allCases)
    func appActivationFollowsOnlyTheAppRule(app: SwitchBehavior, window: SwitchBehavior) {
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = app
            $0.onWindowSwitch = window
        }
        h.memory.record(sourceID: InputSourceInfo.hiragana.id, for: "T") // 저장해 둔 앱 기억
        h.rememberWindow(7, .german)
        h.coordinator.appActivated(previousBundleID: "P", currentBundleID: "T", sourceBeforeActivation: .korean2Set,
                                   previousWindow: 3, currentWindow: { 7 })
        h.scheduler.advance(by: 1)

        let expected: InputSourceInfo = switch app {
        case .keep: .korean2Set
        case .switchToDefault: .abc
        case .restoreLast: window == .restoreLast ? .german : .hiragana // 앞 창 → 앱
        }
        #expect(h.switcher.currentSource == expected)
        // 떠나는 앱·창은 그 기억을 쓰는 옵션일 때만 기록한다
        #expect((h.memory.entries["P"] == InputSourceInfo.korean2Set.id) == (app == .restoreLast))
        #expect((h.coordinator.windowMemory.source(for: 3) == InputSourceInfo.korean2Set.id) == (window == .restoreLast))
    }

    @Test(arguments: SwitchBehavior.allCases, SwitchBehavior.allCases)
    func windowSwitchFollowsOnlyTheWindowRule(app: SwitchBehavior, window: SwitchBehavior) {
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = app
            $0.onWindowSwitch = window
        }
        h.rememberWindow(7, .hiragana)
        h.coordinator.windowSwitched(from: 3, to: 7, current: .korean2Set)
        h.scheduler.advance(by: 1)

        let expected: InputSourceInfo = switch window {
        case .keep: .korean2Set
        case .switchToDefault: .abc
        case .restoreLast: .hiragana
        }
        #expect(h.switcher.currentSource == expected)
        #expect(h.memory.entries.isEmpty) // 창 전환은 앱 기억을 남기지 않는다
        #expect((h.coordinator.windowMemory.source(for: 3) == InputSourceInfo.korean2Set.id) == (window == .restoreLast))
    }

    // MARK: 검증과 재시도 (ADR 0031, 0037, 0039)

    @Test func windowSwitchOverwriteIsCorrectedExactlyOnce() {
        // macOS의 "문서 입력 소스 자동 전환"이 창의 이전 Source를 다시 적용해도 한 번만 바로잡는다
        let h = Harness(current: .korean2Set) { $0.onWindowSwitch = .switchToDefault }
        h.coordinator.windowSwitched(from: 1, to: 2, current: .korean2Set)
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)

        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "T", activeWindow: 2)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .abc)

        h.switcher.currentSource = .korean2Set // 두 번째 되돌림은 그대로 둔다
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "T", activeWindow: 2)
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.count == 2)
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func verificationRetryFallsBackWhenTheTargetWasRemoved() {
        // 기본 입력 소스로 바꾼 뒤 지켜보는 사이 그 Source가 꺼지고 덮어써졌다 → 재시도는 자동 선택으로 대체한다
        let h = Harness(current: .korean2Set) {
            $0.resetOnEscape = true
            $0.defaultSourceID = InputSourceInfo.german.id
        }
        let preferred = InputSourceAction.selectDefault(preferredID: InputSourceInfo.german.id)
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .german)

        h.switcher.known.removeAll { $0.id == InputSourceInfo.german.id }
        h.switcher.currentSource = .korean2Set // 알림 없이 덮어써짐
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed == [preferred, .selectDefault(preferredID: nil)])
        #expect(h.events == [
            .switched(preferred, ok: true),
            .retrying(preferred),
            .switched(.selectDefault(preferredID: nil), ok: true)
        ])
    }

    @Test func disabledPreferredDefaultLeavesALatinLayoutAlone() {
        // 지정한 기본 입력 소스(German)가 꺼졌고 이미 ABC다 → 자동 선택 기준으로 이미 목표라 바꾸지 않는다
        let h = Harness(current: .abc) {
            $0.resetOnEscape = true
            $0.defaultSourceID = InputSourceInfo.german.id
        }
        h.switcher.known.removeAll { $0.id == InputSourceInfo.german.id }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .abc)
        h.scheduler.advance(by: 10)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.events == [.skipped(.selectDefault(preferredID: InputSourceInfo.german.id))])
    }

    // MARK: ESC

    @Test func heldEscapeSwitchesOnce() {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        for _ in 0..<3 {
            h.coordinator.keyDown(keyCode: 53, isAutoRepeat: true, current: .korean2Set)
        }
        h.scheduler.advance(by: 10)
        #expect(h.switcher.performed == [.selectDefault(preferredID: nil)])
    }

    // MARK: 예약 취소·기억 지우기

    @Test func cancelPendingWorkDropsEveryScheduledSwitchButNotLaterOnes() {
        let h = Harness(current: .korean2Set) {
            $0.onAppSwitch = .switchToDefault
            $0.onWindowSwitch = .switchToDefault
            $0.resetOnEscape = true
            $0.resetOnTextFocusLoss = true
        }
        h.activate("A")
        h.coordinator.cancelPendingWork()
        h.scheduler.advance(by: 1)
        h.coordinator.windowSwitched(from: 1, to: 2, current: .korean2Set)
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: .korean2Set)
        h.coordinator.focusChanged(wasTextInput: true, isTextInput: false, current: .korean2Set)
        h.coordinator.cancelPendingWork()
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.events.isEmpty)
        #expect(h.scheduler.pendingCount == 0)

        // 취소가 이후 이벤트를 막지는 않는다(대기 중이던 앱 활성화가 남아 있지 않다)
        h.activate("B", from: "A")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func cancelPendingWorkStopsWatchingTheLastSwitch() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .restoreLast }
        h.activate("A")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay)
        #expect(h.switcher.currentSource == .abc)
        h.coordinator.cancelPendingWork()
        h.switcher.currentSource = .korean2Set
        h.coordinator.sourceChanged(from: .abc, to: .korean2Set, activeBundleID: "A")
        h.scheduler.advance(by: 10)
        #expect(h.switcher.currentSource == .korean2Set)
        #expect(h.switcher.performed.count == 1)
        #expect(h.memory.entries["A"] == InputSourceInfo.korean2Set.id) // 지켜보지 않으므로 그 앱의 선택으로 기록
    }

    @Test func forgettingWhileAnAppSwitchIsSettlingUsesTheDefault() {
        // 대기 중에 "기억한 입력 소스 지우기": 판단 시점에는 기록이 없으므로 기본 입력 소스, 저장소도 비워진다
        let defaults = makeTestDefaults()
        let memory = AppInputMemory(defaults: defaults)
        var settings = KeyHueSettings()
        settings.onAppSwitch = .restoreLast
        settings.onWindowSwitch = .restoreLast
        let switcher = FakeSwitcher(current: .korean2Set)
        let scheduler = FakeScheduler()
        let c = AutoResetCoordinator(switcher: switcher, scheduler: scheduler, memory: memory) { settings }
        memory.record(sourceID: InputSourceInfo.hiragana.id, for: "B")
        c.appActivated(previousBundleID: "A", currentBundleID: "B", sourceBeforeActivation: .korean2Set,
                       previousWindow: 1, currentWindow: { 2 })
        c.forgetRememberedInputs()
        scheduler.advance(by: 1)
        #expect(switcher.currentSource == .abc)
        #expect(c.windowMemory.count == 0)
        #expect(AppInputMemory(defaults: defaults).entries.isEmpty)
    }
}

/// 앱 전환 대기(40 ms) 중 사용자가 단축키·클릭으로 입력 소스를 바꾸면 그 선택을 덮어쓰지 않는다(ADR 0037 확장, 2026-10-03).
/// macOS가 스스로 바꾼 것(문서별 입력 소스)과는 사용자 입력이 있었는지로 구별한다.
@MainActor
@Suite("Manual switch while an app switch settles")
struct ManualSwitchDuringSettleTests {
    private let half = AutoResetCoordinator.appSwitchSettleDelay / 2

    @Test func shortcutThenChangeKeepsTheUsersChoice() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("target.app", from: "previous.app")
        h.scheduler.advance(by: half)
        h.coordinator.userMayHaveSwitchedSource() // ⌘Space
        h.switcher.currentSource = .hiragana
        h.coordinator.sourceChanged(from: .korean2Set, to: .hiragana, activeBundleID: "target.app")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.switcher.currentSource == .hiragana)
        #expect(h.events == [.keptManualSwitch])
    }

    @Test func restoringMemoryAlsoYieldsToTheUser() {
        let h = Harness(current: .abc) { $0.onAppSwitch = .restoreLast }
        h.memory.record(sourceID: InputSourceInfo.korean2Set.id, for: "target.app")
        h.activate("target.app")
        h.coordinator.userMayHaveSwitchedSource()
        h.switcher.currentSource = .hiragana
        h.coordinator.sourceChanged(from: .abc, to: .hiragana, activeBundleID: "target.app")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.memory.entries["target.app"] == InputSourceInfo.hiragana.id)
    }

    @Test func changeWithoutUserInputIsMacOSAndStillSwitches() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("target.app")
        h.scheduler.advance(by: half)
        h.switcher.currentSource = .hiragana // macOS restores the document's source
        h.coordinator.sourceChanged(from: .korean2Set, to: .hiragana, activeBundleID: "target.app")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func plainTypingDoesNotCountAsAManualSwitch() {
        // 앱을 바꾸자마자 치기 시작해도 자동 전환은 그대로 일어난다. 글자 키는 userMayHaveSwitchedSource를 부르지 않는다.
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("target.app")
        h.coordinator.keyDown(keyCode: 0, isAutoRepeat: false, current: .korean2Set)
        h.switcher.currentSource = .hiragana
        h.coordinator.sourceChanged(from: .korean2Set, to: .hiragana, activeBundleID: "target.app")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func shortcutWithoutAChangeLeavesTheSwitchInPlace() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("target.app")
        h.coordinator.userMayHaveSwitchedSource() // ⌘C: no source change follows
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func intentDoesNotCarryOverToTheNextActivation() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.activate("first.app")
        h.coordinator.userMayHaveSwitchedSource()
        h.scheduler.advance(by: 1) // first.app switched to ABC
        h.switcher.currentSource = .korean2Set
        h.activate("second.app", from: "first.app")
        h.switcher.currentSource = .hiragana
        h.coordinator.sourceChanged(from: .korean2Set, to: .hiragana, activeBundleID: "second.app")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func outsideTheSettleDelayTheExistingRulesApply() {
        let h = Harness(current: .korean2Set) { $0.onAppSwitch = .switchToDefault }
        h.coordinator.userMayHaveSwitchedSource() // Nothing pending: ignored
        h.activate("target.app")
        h.switcher.currentSource = .hiragana
        h.coordinator.sourceChanged(from: .korean2Set, to: .hiragana, activeBundleID: "target.app")
        h.scheduler.advance(by: 1)
        #expect(h.switcher.currentSource == .abc)
    }
}
