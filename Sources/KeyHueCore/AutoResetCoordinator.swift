import Foundation

/// 입력 소스를 읽고 바꾸는 쪽. 앱에서는 TIS(InputSourceController), 테스트에서는 가짜 구현.
@MainActor
public protocol InputSourceSwitching: AnyObject {
    var currentSource: InputSourceInfo? { get }
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
    public static let appSwitchSettleDelay: TimeInterval = 0.1
    /// 전환 결과 확인까지의 시간. 목표에 도달하지 않았으면 한 번만 재시도한다.
    public static let verifyDelay: TimeInterval = 0.25

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
    private let settings: () -> KeyHueSettings

    /// 전환 시도마다 호출된다. 앱은 로그를 남기고 입력 소스 모니터를 새로 읽는다.
    public var onEvent: ((Event) -> Void)?

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
    /// - Parameters:
    ///   - sourceBeforeActivation: 전환 직전(이전 앱에서) 알고 있던 Source. 이전 앱 몫으로 기록한다.
    ///   - refresh: 놓친 알림을 보정하려고 실제 상태를 다시 읽고, 새 앱에서의 Source를 돌려준다.
    public func appActivated(
        previousBundleID: String?,
        currentBundleID: String?,
        sourceBeforeActivation: InputSourceInfo?,
        refresh: () -> InputSourceInfo?
    ) {
        let settings = settings()
        // 이전 앱에서 Source 변경이 한 번도 없었던 경우를 위해, 전환 직전 Source를 이전 앱 몫으로 기록한다.
        if settings.rememberInputPerApp, let previousBundleID, let sourceID = sourceBeforeActivation?.id {
            memory.record(sourceID: sourceID, for: previousBundleID)
        }
        let current = refresh()
        perform(
            ResetPolicy.onAppActivated(bundleID: currentBundleID, settings: settings, remembered: memory.entries, current: current),
            after: Self.appSwitchSettleDelay
        )
    }

    public func keyDown(keyCode: Int64, isAutoRepeat: Bool, current: InputSourceInfo?) {
        perform(ResetPolicy.onKeyDown(keyCode: keyCode, isAutoRepeat: isAutoRepeat, settings: settings(), current: current))
    }

    public func focusChanged(wasTextInput: Bool, isTextInput: Bool, current: InputSourceInfo?) {
        perform(ResetPolicy.onFocusChanged(wasTextInput: wasTextInput, isTextInput: isTextInput, settings: settings(), current: current))
    }

    /// 활성 앱에서 Source가 바뀌었다 → 앱별 기억에 기록.
    public func sourceChanged(from old: InputSourceInfo?, to new: InputSourceInfo?, activeBundleID: String?) {
        guard settings().rememberInputPerApp,
              let sourceID = new?.id, sourceID != old?.id,
              let activeBundleID else { return }
        memory.record(sourceID: sourceID, for: activeBundleID)
    }

    // MARK: 실행

    /// 이벤트 처리(키 입력, 앱 활성화)가 끝난 뒤 전환한다.
    func perform(_ action: InputSourceAction, after delay: TimeInterval = 0, retry: Bool = true) {
        guard action != .none else { return }
        scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            // 대기하는 사이 사용자가 직접 전환했을 수 있으므로 다시 확인한다.
            guard !ResetPolicy.isSatisfied(action, by: self.switcher.currentSource) else {
                self.onEvent?(.skipped(action))
                return
            }
            let ok = self.switcher.perform(action)
            self.onEvent?(.switched(action, ok: ok))
            guard retry else { return }
            self.scheduler.schedule(after: Self.verifyDelay) { [weak self] in
                guard let self, !ResetPolicy.isSatisfied(action, by: self.switcher.currentSource) else { return }
                self.onEvent?(.retrying(action))
                self.perform(action, retry: false)
            }
        }
    }
}
