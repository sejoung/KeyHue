import Foundation
import Testing
@testable import KeyHueCore

/// 가짜 입력 소스 전환기: 전환하면 목표 Source가 현재 Source가 된다.
@MainActor
final class FakeSwitcher: InputSourceSwitching {
    var currentSource: InputSourceInfo?
    private(set) var performed: [InputSourceAction] = []
    var known: [InputSourceInfo] = [.abc, .us, .german, .korean2Set, .hiragana]

    init(current: InputSourceInfo?) {
        currentSource = current
    }

    func perform(_ action: InputSourceAction) -> Bool {
        performed.append(action)
        switch action {
        case .none:
            return false
        case .selectDefault(let preferredID):
            currentSource = DefaultInputSourcePicker.pick(from: known, preferredID: preferredID)
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

private func makeDefaults() -> UserDefaults {
    let suite = "KeyHueTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
private final class Harness {
    var settings = KeyHueSettings()
    let switcher: FakeSwitcher
    let scheduler = FakeScheduler()
    let memory = AppInputMemory(defaults: makeDefaults())
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
            sourceBeforeActivation: switcher.currentSource,
            refresh: { self.switcher.currentSource }
        )
    }
}

@MainActor
@Suite("AutoResetCoordinator")
struct AutoResetCoordinatorTests {
    @Test func escapeSwitchesOnNextRunLoop() {
        let h = Harness(current: .korean2Set) { $0.resetOnEscape = true }
        h.coordinator.keyDown(keyCode: 53, isAutoRepeat: false, current: h.switcher.currentSource)
        #expect(h.switcher.performed.isEmpty) // 이벤트 처리 중에는 바꾸지 않는다
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.events == [.switched(.selectDefault(preferredID: nil), ok: true)])
    }

    @Test func appSwitchWaitsForActivationToSettle() {
        let h = Harness(current: .korean2Set) { $0.resetOnAppSwitch = true }
        h.activate("com.apple.Terminal")
        h.scheduler.advance(by: AutoResetCoordinator.appSwitchSettleDelay - 0.01)
        #expect(h.switcher.performed.isEmpty)
        h.scheduler.advance(by: 0.01)
        #expect(h.switcher.currentSource == .abc)
    }

    @Test func skipsWhenUserAlreadySwitchedWhileWaiting() {
        let h = Harness(current: .korean2Set) { $0.resetOnAppSwitch = true }
        h.activate("com.apple.Terminal")
        h.switcher.currentSource = .abc // 대기 중 사용자가 직접 바꿈
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.isEmpty)
        #expect(h.events == [.skipped(.selectDefault(preferredID: nil))])
    }

    /// 실측한 경쟁 상태: 전환 직후 시스템이 새 앱에 이전 Source를 다시 적용한다(ADR 0007).
    @Test func retriesOnceWhenSystemOverridesTheSwitch() {
        let h = Harness(current: .korean2Set) { $0.resetOnAppSwitch = true }
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
        let h = Harness(current: .korean2Set) { $0.rememberInputPerApp = true }
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
        let h = Harness(current: .abc) {
            $0.rememberInputPerApp = true
            $0.resetOnAppSwitch = true
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
        let h = Harness(current: .korean2Set) { $0.rememberInputPerApp = true }
        h.coordinator.sourceChanged(from: .korean2Set, to: .abc, activeBundleID: nil)
        h.coordinator.sourceChanged(from: .abc, to: .abc, activeBundleID: "a")
        #expect(h.memory.entries.isEmpty)
    }

    @Test func decidesWithRefreshedSourceNotStaleOne() {
        // 알림을 놓쳐 저장된 값은 한국어였지만, 다시 읽어 보니 이미 ABC → 아무것도 하지 않는다.
        let h = Harness(current: .korean2Set) { $0.resetOnAppSwitch = true }
        h.coordinator.appActivated(
            previousBundleID: nil,
            currentBundleID: "x",
            sourceBeforeActivation: .korean2Set,
            refresh: {
                h.switcher.currentSource = .abc
                return .abc
            }
        )
        #expect(h.scheduler.pendingCount == 0)
    }
}
