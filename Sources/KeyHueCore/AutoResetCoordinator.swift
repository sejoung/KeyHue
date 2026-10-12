import Foundation

/// 입력 소스를 읽고 바꾸는 쪽. 앱에서는 TIS(InputSourceController), 테스트에서는 가짜 구현.
@MainActor
public protocol InputSourceSwitching: AnyObject {
    var currentSource: InputSourceInfo? { get }
    var availableSources: [InputSourceInfo] { get }
    @discardableResult func perform(_ action: InputSourceAction) -> Bool
}

/// 1회성 지연 실행. 앱에서는 DispatchQueue.main.asyncAfter, 테스트에서는 시간을 직접 흘린다.
/// 반복 타이머(polling)가 아니다.
@MainActor
public protocol Scheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

/// 자동 전환(앱 전환, ESC, 텍스트 필드 이탈)과 앱별 입력 기억을 조정한다(ADR 0007, 0022).
///
/// - 무엇으로 바꿀지는 `ResetPolicy`가 정한다.
/// - 이 객체는 **언제** 바꿀지(지연), 바꾼 뒤 **확인하고 한 번 재시도**할지, 앱별 기억을 **언제 기록**할지를 맡는다.
@MainActor
public final class AutoResetCoordinator {
    /// 앱 활성화 직후에는 시스템(TSM)이 새 앱에 기존 Source를 다시 적용하므로, 그보다 먼저 전환하면
    /// 덮어써지거나 색이 한 번 깜빡인다. 활성화가 끝날 때까지 잠깐 기다린 뒤 전환한다.
    /// 실측(ADR 0031): 활성화 후 0 ms에 바꾸면 45%, 10 ms면 10%가 덮어써지고 20 ms 이상은 0/88. 두 배 여유를 둔다.
    public static let appSwitchSettleDelay: TimeInterval = 0.04
    /// 전환 결과를 지켜보는 시간. 이 안에 덮어써지면 입력 소스 알림을 받는 즉시 한 번만 다시 바꾸고,
    /// 알림을 놓쳤을 때를 위해 끝에 한 번 더 확인한다.
    /// 시스템 덮어쓰기 알림은 활성화 후 12–36 ms에 온다(실측, 전환은 40 ms). 길면 사용자가 직접 바꾼 것까지
    /// 되돌리므로(⌘Tab 직후 ⌘Space) 짧게 둔다(ADR 0037).
    public static let verifyDelay: TimeInterval = 0.1

    public enum Event: Equatable, Sendable {
        /// 실행 직전 이미 목표 상태라 건너뜀(대기 중 사용자가 직접 바꾼 경우 등)
        case skipped(InputSourceAction)
        case switched(InputSourceAction, ok: Bool)
        /// 확인해 보니 덮어써져 있어 한 번 더 시도
        case retrying(InputSourceAction)
        /// 앱 전환 대기 중 사용자가 직접 바꿨다(단축키·클릭 뒤 변경). 그 앱의 자동 전환을 하지 않는다.
        case keptManualSwitch
    }

    private let switcher: InputSourceSwitching
    private let scheduler: Scheduling
    private let memory: AppInputRemembering
    /// 창별 기억(앱 실행 중에만). 창 식별자는 앱이 정한다(AX 창 요소, CFEqual/CFHash).
    public private(set) var windowMemory = WindowInputMemory<AnyHashable>()
    private let settings: () -> KeyHueSettings
    /// 방금 전환한 동작. 지켜보는 동안 덮어써지면 바로 다시 바꾼다(한 번만).
    private var watched = PendingSlot<InputSourceAction>()
    /// 대기(`appSwitchSettleDelay`) 중인 앱 활성화. 이 사이에 온 이벤트는 그 앱의 전환이 아직 일어나지 않은 상태에서 온다.
    private var settling = PendingSlot<Void>()
    /// 대기 중인 창 전환. 앱 전환의 `settling`과 같은 역할(ADR 0028·0043): 대기가 끝나기 전에
    /// 다른 창·앱으로 옮기면 그 창의 전환은 일어나지 않았으므로 기록하지도 실행하지도 않는다.
    private var windowSettling = PendingSlot<Void>()
    /// 앱 전환 대기 중 단축키·클릭이 있었다. 이어서 Source가 바뀌면 사용자의 선택으로 본다.
    private var userInputWhileSettling = false
    /// 예약한 전환(키 입력·포커스·창 전환 뒤)의 세대. 올리면 아직 실행되지 않은 것이 모두 취소된다.
    private var pendingGeneration = 0

    /// 전환 시도마다 호출된다. 앱은 로그를 남기고 입력 소스 모니터를 새로 읽는다.
    public var onEvent: ((Event) -> Void)?
    /// Distinguishes utility-owned selections from system/manual source changes.
    public var onWillSwitch: (() -> Void)?

    /// 지금 설정과 Source 목록으로 본 입력기 통합. One TIS read per decision: the source list is built anew on every read.
    private func currentIntegration() -> IntegratedActionResolver {
        IntegratedActionResolver(settings: settings(), sources: switcher.availableSources)
    }

    /// Recovery/settings changes must cancel delayed app/window actions and verification.
    public func cancelPendingWork() {
        pendingGeneration += 1
        settling.cancel()
        windowSettling.cancel()
        userInputWhileSettling = false
        watched.cancel()
    }

    public init(
        switcher: InputSourceSwitching,
        scheduler: Scheduling,
        memory: AppInputRemembering,
        settings: @escaping () -> KeyHueSettings
    ) {
        self.switcher = switcher
        self.scheduler = scheduler
        self.memory = memory
        self.settings = settings
    }

    // MARK: 이벤트

    /// 다른 앱이 활성화됐다.
    ///
    /// 무엇으로 바꿀지는 대기(`appSwitchSettleDelay`)가 끝나는 시점에 실제 Source와 새 앱의 앞 창으로 판단한다.
    /// 그래서 호출자는 이 호출 **뒤에** 새 앱에 붙는 작업(AX 등)을 해도 전환이 늦어지지 않는다.
    /// - Parameters:
    ///   - sourceBeforeActivation: 전환 직전(이전 앱에서) 알고 있던 Source. 이전 앱 몫으로 기록한다.
    ///   - previousWindow: 떠나는 앱의 메인 창(창별 기억용). 없으면 nil.
    ///   - currentWindow: 판단 시점의 새 앱 메인 창(창별 기억용). 없으면 nil.
    public func appActivated(
        previousBundleID: String?,
        currentBundleID: String?,
        sourceBeforeActivation: InputSourceInfo?,
        previousWindow: AnyHashable? = nil,
        currentWindow: @escaping @MainActor () -> AnyHashable? = { nil }
    ) {
        let settings = settings()
        // 이전 앱이 아직 대기 중이었다(40 ms 안에 또 전환): 그 앱의 전환은 일어나지 않았으므로 지금 Source는 그 앱 것이 아니다.
        // 기록하지 않고, 예약된 그 앱의 전환은 아래 세대 번호로 취소한다.
        let previousNeverSettled = settling.isPending
        // 떠나는 앱에서 창 전환이 아직 대기 중이었다: 그 창의 전환은 일어나지 않았고 지금 Source는 그 창 것이 아니다.
        // 기록하지 않고, 예약된 창 전환은 취소한다(새 앱에서 실행되면 새 앱의 기억을 덮는다).
        let previousWindowNeverSettled = windowSettling.isPending
        windowSettling.cancel()
        // 이전 앱에서 Source 변경이 한 번도 없었던 경우를 위해, 전환 직전 Source를 이전 앱(창) 몫으로 기록한다.
        if !previousNeverSettled, settings.rememberInputPerApp, let previousBundleID, let sourceID = sourceBeforeActivation?.id {
            memory.record(sourceID: sourceID, for: previousBundleID)
        }
        if !previousNeverSettled, !previousWindowNeverSettled, settings.remembersInputPerWindow(in: previousBundleID), let previousWindow,
           let sourceID = sourceBeforeActivation?.id {
            windowMemory.record(sourceID: sourceID, for: previousWindow, app: previousBundleID)
        }
        if settings.integrateInputMethod {
            pendingGeneration += 1
            watched.cancel()
        }
        let activation = settling.start()
        userInputWhileSettling = false
        scheduler.schedule(after: Self.appSwitchSettleDelay) { [weak self] in
            guard let self, self.settling.finish(activation) else { return }
            let integration = self.currentIntegration()
            // Only the new app's memory is needed, not every app's.
            let remembered = currentBundleID.flatMap { id in self.memory.entries[id].map { [id: integration.sourceID($0)] } } ?? [:]
            let action = ResetPolicy.onAppActivated(
                bundleID: currentBundleID,
                settings: integration.effectiveSettings,
                remembered: remembered,
                rememberedForWindow: currentWindow().flatMap(self.windowMemory.source(for:)).map(integration.sourceID),
                current: self.switcher.currentSource,
                availableSourceIDs: Set(integration.sources.map(\.id))
            )
            guard action != .none else { return }
            self.execute(action, retry: true)
        }
    }

    /// 입력 소스를 바꿀 수 있는 사용자 입력: 수정 키가 붙은 키(⌘Space, ⌃Space 등)나 마우스 클릭(입력 메뉴).
    /// 글자 키는 해당하지 않는다(앱을 바꾸자마자 치기 시작해도 자동 전환은 일어나야 한다).
    /// 앱 전환 대기 중이 아니면 아무것도 하지 않는다.
    public func userMayHaveSwitchedSource() {
        if settling.isPending { userInputWhileSettling = true }
    }

    public func keyDown(keyCode: Int64, isAutoRepeat: Bool, current: InputSourceInfo?) {
        // 사용자가 키를 누르기 시작했다 → 방금 한 자동 전환은 더 지켜보지 않는다. 이후 변경은 사용자의 선택이다(ADR 0037).
        watched.cancel()
        if settings().integrateInputMethod { cancelPendingWork() }
        perform(ResetPolicy.onKeyDown(keyCode: keyCode, isAutoRepeat: isAutoRepeat, settings: currentIntegration().effectiveSettings, current: current))
    }

    public func focusChanged(wasTextInput: Bool, isTextInput: Bool, current: InputSourceInfo?) {
        let settings = currentIntegration().effectiveSettings
        perform(ResetPolicy.onFocusChanged(wasTextInput: wasTextInput, isTextInput: isTextInput, settings: settings, current: current))
    }

    /// 같은 앱 안에서 다른 창으로 옮겼다. 창마다 입력 소스를 되살리는 macOS 설정("문서 입력 소스 자동 전환")과
    /// 겹치지 않도록 앱 전환과 같이 잠깐 기다린 뒤 전환하고 한 번 검증한다.
    ///   - from: 떠난 창. 창별 기억이 켜져 있으면 떠나기 직전 Source(`current`)를 이 창 몫으로 기록한다.
    ///   - to: 옮겨 간 창. 기록이 있으면 되살린다.
    ///   - bundleID: 창이 바뀐 앱. 그 앱의 창 동작을 따른다(ADR 0089).
    public func windowSwitched(from previous: AnyHashable? = nil, to window: AnyHashable? = nil, in bundleID: String? = nil,
                               current: InputSourceInfo?) {
        // 앱 전환 대기 중의 창 변경(뒤에 있던 앱의 다른 창을 눌러 활성화)은 앱 전환의 일부다.
        // 대기가 끝날 때 앱 전환이 그때의 앞 창으로 판단하므로 따로 기록·전환하지 않는다.
        // (기록하면 아직 이전 앱의 Source를 이 앱의 창 몫으로 남기고, 전환하면 앱 전환 결과를 덮는다.)
        guard !settling.isPending else { return }
        let settings = settings()
        // 떠난 창도 대기 중이었다(40 ms 안에 또 옮김): 지금 Source는 그 창 것이 아니다.
        if !windowSettling.isPending, settings.remembersInputPerWindow(in: bundleID), let previous, let sourceID = current?.id {
            windowMemory.record(sourceID: sourceID, for: previous, app: bundleID)
        }
        if settings.integrateInputMethod { pendingGeneration += 1 }
        let pending = pendingGeneration
        let token = windowSettling.start()
        scheduler.schedule(after: Self.appSwitchSettleDelay) { [weak self] in
            guard let self, self.pendingGeneration == pending, self.windowSettling.finish(token) else { return }
            let integration = self.currentIntegration()
            let action = ResetPolicy.onWindowSwitched(
                settings: integration.effectiveSettings,
                bundleID: bundleID,
                rememberedForWindow: window.flatMap(self.windowMemory.source(for:)).map(integration.sourceID),
                current: self.switcher.currentSource
            )
            if action != .none { self.execute(action, retry: true) }
        }
    }

    /// 활성 앱에서 Source가 바뀌었다 → 앱별·창별 기억에 기록. 방금 자동 전환한 것이 덮어써졌으면 바로 다시 바꾼다.
    public func sourceChanged(
        from old: InputSourceInfo?,
        to new: InputSourceInfo?,
        activeBundleID: String?,
        activeWindow: AnyHashable? = nil
    ) {
        let settings = settings()
        guard let sourceID = new?.id, sourceID != old?.id else { return }
        // 방금 바꾼 것을 시스템이 되돌렸다 → 마지막 확인을 기다리지 않고 바로 한 번 더 바꾼다.
        // 알림 처리(상태 저장소 관찰자) 안에서 다시 바꾸지 않도록 다음 차례로 미룬다. 되돌려진 Source는 기억하지 않는다.
        if let action = watched.value, !ResetPolicy.isSatisfied(action, by: new) {
            watched.cancel()
            onEvent?(.retrying(action))
            perform(action, after: 0, retry: false)
            return
        }
        // 앱 전환 대기 중 단축키·클릭 뒤의 변경은 사용자의 선택이다(ADR 0037). macOS가 스스로 바꾼 것(문서별
        // 입력 소스)과는 사용자 입력이 있었는지로 구별한다. 대기 중인 결정을 취소하고, 아래에서 새 앱 몫으로 기록한다.
        if settling.isPending {
            // 사용자 입력 없이 대기 중에 바뀌었다: macOS가 새 앱에 문서별 Source를 다시 적용한 것이다.
            // 기억하면 "마지막 입력 소스로 복원"이 사용자가 실제로 쓴 Source 대신 이것을 복원한다.
            guard userInputWhileSettling else { return }
            settling.cancel()
            userInputWhileSettling = false
            onEvent?(.keptManualSwitch)
        }
        if settings.rememberInputPerApp, let activeBundleID {
            memory.record(sourceID: sourceID, for: activeBundleID)
        }
        if settings.remembersInputPerWindow(in: activeBundleID), let activeWindow {
            windowMemory.record(sourceID: sourceID, for: activeWindow, app: activeBundleID)
        }
    }

    /// 창마다 기억하던 앱이 더는 그러지 않으면(목록에서 빠지거나 목록이 적용되지 않음) 그 앱의 창 기록을 지운다(ADR 0089).
    public func settingsChanged(from old: KeyHueSettings, to new: KeyHueSettings) {
        for app in old.windowMemoryApps where old.remembersInputPerWindow(in: app) && !new.remembersInputPerWindow(in: app) {
            windowMemory.forget(app: app)
        }
    }

    /// "기억한 입력 소스 지우기": 앱별·창별 기억을 모두 지운다.
    public func forgetRememberedInputs() {
        memory.clear()
        windowMemory.clear()
    }

    // MARK: 실행

    /// 이벤트 처리(키 입력, 창 전환)가 끝난 뒤 전환한다.
    func perform(_ action: InputSourceAction, after delay: TimeInterval = 0, retry: Bool = true) {
        guard action != .none else { return }
        let pending = pendingGeneration
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.pendingGeneration == pending else { return }
            self.execute(action, retry: retry)
        }
    }

    private func execute(_ requested: InputSourceAction, retry: Bool) {
        // 새 전환 요청이 이전 요청의 검증을 대체한다. 새 대상이 없거나 전환에 실패해도 이전 대상으로 되돌리지 않는다.
        watched.cancel()
        // 예약 후 입력기가 삭제될 수도 있다. 실행 직전에 후보를 확인하고 실제 대체 동작을 검증한다.
        let integration = currentIntegration()
        var action = integration.resolve(requested, current: switcher.currentSource)
        guard action != .none else {
            onEvent?(.skipped(requested))
            return
        }
        // 대기하는 사이 사용자가 직접 전환했을 수 있으므로 다시 확인한다.
        guard !ResetPolicy.isSatisfied(action, by: switcher.currentSource) else {
            onEvent?(.skipped(action))
            return
        }
        onWillSwitch?()
        var ok = switcher.perform(action)
        // KeyHue 모드가 실행되지 않았다: 대체 동작을 한 번만 시도하고, 그것은 지켜보지 않는다.
        let integrationFailed = integration.needsFallback(after: action, ok: ok)
        if integrationFailed {
            action = integration.fallback(current: switcher.currentSource)
            if action != .none, !ResetPolicy.isSatisfied(action, by: switcher.currentSource) {
                ok = switcher.perform(action)
            }
        }
        onEvent?(.switched(action, ok: ok))
        guard retry, ok, !integrationFailed else { return }
        let token = watched.start(action)
        // 알림을 놓쳤을 때를 위한 마지막 확인. 이미 알림으로 다시 바꿨으면 하지 않는다.
        scheduler.schedule(after: Self.verifyDelay) { [weak self] in
            guard let self, self.watched.finish(token) else { return }
            guard !ResetPolicy.isSatisfied(action, by: self.switcher.currentSource) else { return }
            self.onEvent?(.retrying(action))
            self.execute(action, retry: false)
        }
    }
}
