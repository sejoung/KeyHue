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
    }

    private let switcher: InputSourceSwitching
    private let scheduler: Scheduling
    private let memory: AppInputMemory
    /// 창별 기억(앱 실행 중에만). 창 식별자는 앱이 정한다(AX 창 요소, CFEqual/CFHash).
    public private(set) var windowMemory = WindowInputMemory<AnyHashable>()
    private let settings: () -> KeyHueSettings
    /// 방금 전환한 동작. 지켜보는 동안 덮어써지면 바로 다시 바꾼다(한 번만).
    private var watched: (action: InputSourceAction, generation: Int)?
    private var generation = 0
    /// 대기(`appSwitchSettleDelay`) 중인 앱 활성화. 이 사이에 온 이벤트는 그 앱의 전환이 아직 일어나지 않은 상태에서 온다.
    private var settling: (bundleID: String?, generation: Int)?
    private var activationGeneration = 0

    /// 전환 시도마다 호출된다. 앱은 로그를 남기고 입력 소스 모니터를 새로 읽는다.
    public var onEvent: ((Event) -> Void)?
    /// Distinguishes utility-owned selections from system/manual source changes.
    public var onWillSwitch: (() -> Void)?
    private var pendingGeneration = 0

    private var effectiveSettings: KeyHueSettings {
        InputMethodIntegration.effectiveSettings(settings(), sources: switcher.availableSources)
    }

    private func effectiveSourceID(_ id: String) -> String {
        InputMethodIntegration.sourceID(id, settings: settings(), sources: switcher.availableSources)
    }

    /// Recovery/settings changes must cancel delayed app/window actions and verification.
    public func cancelPendingWork() {
        pendingGeneration += 1
        activationGeneration += 1
        settling = nil
        watched = nil
    }

    public init(
        switcher: InputSourceSwitching,
        scheduler: Scheduling,
        memory: AppInputMemory,
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
        let previousNeverSettled = settling != nil
        // 이전 앱에서 Source 변경이 한 번도 없었던 경우를 위해, 전환 직전 Source를 이전 앱(창) 몫으로 기록한다.
        if !previousNeverSettled, settings.rememberInputPerApp, let previousBundleID, let sourceID = sourceBeforeActivation?.id {
            memory.record(sourceID: sourceID, for: previousBundleID)
        }
        if !previousNeverSettled, settings.rememberInputPerWindow, let previousWindow, let sourceID = sourceBeforeActivation?.id {
            windowMemory.record(sourceID: sourceID, for: previousWindow)
        }
        if settings.integrateInputMethod {
            pendingGeneration += 1
            watched = nil
        }
        activationGeneration += 1
        let activation = activationGeneration
        settling = (currentBundleID, activation)
        scheduler.schedule(after: Self.appSwitchSettleDelay) { [weak self] in
            guard let self, self.settling?.generation == activation else { return }
            self.settling = nil
            let action = ResetPolicy.onAppActivated(
                bundleID: currentBundleID,
                settings: self.effectiveSettings,
                remembered: self.memory.entries.mapValues(self.effectiveSourceID),
                rememberedForWindow: currentWindow().flatMap(self.windowMemory.source(for:)).map(self.effectiveSourceID),
                current: self.switcher.currentSource,
                availableSourceIDs: Set(self.switcher.availableSources.map(\.id))
            )
            guard action != .none else { return }
            self.execute(action, retry: true)
        }
    }

    public func keyDown(keyCode: Int64, isAutoRepeat: Bool, current: InputSourceInfo?) {
        // 사용자가 키를 누르기 시작했다 → 방금 한 자동 전환은 더 지켜보지 않는다. 이후 변경은 사용자의 선택이다(ADR 0037).
        watched = nil
        if settings().integrateInputMethod { cancelPendingWork() }
        perform(ResetPolicy.onKeyDown(keyCode: keyCode, isAutoRepeat: isAutoRepeat, settings: effectiveSettings, current: current))
    }

    public func focusChanged(wasTextInput: Bool, isTextInput: Bool, current: InputSourceInfo?) {
        perform(ResetPolicy.onFocusChanged(wasTextInput: wasTextInput, isTextInput: isTextInput, settings: effectiveSettings, current: current))
    }

    /// 같은 앱 안에서 다른 창으로 옮겼다. 창마다 입력 소스를 되살리는 macOS 설정("문서 입력 소스 자동 전환")과
    /// 겹치지 않도록 앱 전환과 같이 잠깐 기다린 뒤 전환하고 한 번 검증한다.
    ///   - from: 떠난 창. 창별 기억이 켜져 있으면 떠나기 직전 Source(`current`)를 이 창 몫으로 기록한다.
    ///   - to: 옮겨 간 창. 기록이 있으면 되살린다.
    public func windowSwitched(from previous: AnyHashable? = nil, to window: AnyHashable? = nil, current: InputSourceInfo?) {
        // 앱 전환 대기 중의 창 변경(뒤에 있던 앱의 다른 창을 눌러 활성화)은 앱 전환의 일부다.
        // 대기가 끝날 때 앱 전환이 그때의 앞 창으로 판단하므로 따로 기록·전환하지 않는다.
        // (기록하면 아직 이전 앱의 Source를 이 앱의 창 몫으로 남기고, 전환하면 앱 전환 결과를 덮는다.)
        guard settling == nil else { return }
        let settings = settings()
        if settings.rememberInputPerWindow, let previous, let sourceID = current?.id {
            windowMemory.record(sourceID: sourceID, for: previous)
        }
        if settings.integrateInputMethod { pendingGeneration += 1 }
        let pending = pendingGeneration
        scheduler.schedule(after: Self.appSwitchSettleDelay) { [weak self] in
            guard let self, self.pendingGeneration == pending else { return }
            let action = ResetPolicy.onWindowSwitched(
                settings: self.effectiveSettings,
                rememberedForWindow: window.flatMap(self.windowMemory.source(for:)).map(self.effectiveSourceID),
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
        if let watched, !ResetPolicy.isSatisfied(watched.action, by: new) {
            self.watched = nil
            onEvent?(.retrying(watched.action))
            perform(watched.action, after: 0, retry: false)
            return
        }
        if settings.rememberInputPerApp, let activeBundleID {
            memory.record(sourceID: sourceID, for: activeBundleID)
        }
        if settings.rememberInputPerWindow, let activeWindow {
            windowMemory.record(sourceID: sourceID, for: activeWindow)
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
        watched = nil
        // 예약 후 입력기가 삭제될 수도 있다. 실행 직전에 후보를 확인하고 실제 대체 동작을 검증한다.
        let originalSettings = settings()
        let sources = switcher.availableSources
        let mapped: InputSourceAction
        switch requested {
        case .none: mapped = .none
        case .select(let id): mapped = .select(sourceID: effectiveSourceID(id))
        case .selectDefault(let id):
            var preference = originalSettings
            // The policy can have resolved the effective default before the mode
            // roster changed. Revert to the saved default if the pair disappeared.
            let saved = originalSettings.defaultSourceID
            let resolvedFromSaved = id == InputMethodIntegration.latinID && (saved == nil || saved == InputMethodIntegration.abcID)
                || id == InputMethodIntegration.hangulID && saved == InputMethodIntegration.systemHangulID
            if originalSettings.integrateInputMethod, resolvedFromSaved, !InputMethodIntegration.isAvailable(in: sources) {
                preference.defaultSourceID = originalSettings.defaultSourceID
            } else {
                preference.defaultSourceID = id
            }
            mapped = .selectDefault(preferredID: InputMethodIntegration.effectiveSettings(preference, sources: sources).defaultSourceID)
        }
        var action = DefaultInputSourcePicker.resolve(
            mapped,
            from: switcher.availableSources,
            current: switcher.currentSource,
            preferredDefaultID: effectiveSettings.defaultSourceID
        )
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
        // A registered mode may still fail to launch. Try the saved default once,
        // without routing that fallback back into the failing mode or watching it.
        let integrationFailed = !ok && originalSettings.integrateInputMethod && (
            action == .select(sourceID: InputMethodIntegration.latinID)
            || action == .select(sourceID: InputMethodIntegration.hangulID)
            || action == .selectDefault(preferredID: InputMethodIntegration.latinID)
            || action == .selectDefault(preferredID: InputMethodIntegration.hangulID)
        )
        if integrationFailed {
            let savedID = originalSettings.defaultSourceID
            let fallbackID = savedID == InputMethodIntegration.latinID || savedID == InputMethodIntegration.hangulID ? nil : savedID
            action = DefaultInputSourcePicker.resolve(.selectDefault(preferredID: fallbackID), from: sources,
                                                     current: switcher.currentSource, preferredDefaultID: fallbackID)
            // Automatic picking can land on a KeyHue mode when no system Latin
            // layout is enabled. Choose among system sources only, or stay put.
            let keyHueIDs: Set<String> = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
            if case .selectDefault(let preferredID) = action,
               let picked = DefaultInputSourcePicker.pick(from: sources, preferredID: preferredID), keyHueIDs.contains(picked.id) {
                action = DefaultInputSourcePicker.pick(from: sources.filter { !keyHueIDs.contains($0.id) }, preferredID: fallbackID)
                    .map { .select(sourceID: $0.id) } ?? .none
            }
            if action != .none, !ResetPolicy.isSatisfied(action, by: switcher.currentSource) {
                ok = switcher.perform(action)
            }
        }
        onEvent?(.switched(action, ok: ok))
        guard retry, ok, !integrationFailed else { return }
        generation += 1
        let current = generation
        watched = (action, current)
        // 알림을 놓쳤을 때를 위한 마지막 확인. 이미 알림으로 다시 바꿨으면 하지 않는다.
        scheduler.schedule(after: Self.verifyDelay) { [weak self] in
            guard let self, self.watched?.generation == current else { return }
            self.watched = nil
            guard !ResetPolicy.isSatisfied(action, by: self.switcher.currentSource) else { return }
            self.onEvent?(.retrying(action))
            self.execute(action, retry: false)
        }
    }
}
