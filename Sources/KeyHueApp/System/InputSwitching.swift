import AppKit
import KeyHueCore

/// KeyHue가 입력 소스를 바꾸는 부품들: 자동 전환(Core), 입력기 두 모드 라우팅, 입력기 세션 복구.
/// 서로의 시작·끝을 알려 주도록 연결하고, 앱은 OS 이벤트만 넘긴다.
@MainActor
final class InputSwitching {
    private let shortcutPoster = InputSourceShortcutPoster()
    private let acknowledgementMonitor = InputMethodAcknowledgementMonitor()
    /// Posts a terminal fix's Backspace keys for the input method (ADR 0073).
    private let terminalKeyPostServer = TerminalKeyPostServer()

    /// KeyHue 자신의 선택은 모두 이 전환기를 거친다. KeyHue 모드를 고르면 입력기 세션 확인을 시작한다(ADR 0062).
    private let switcher = SystemInputSourceSwitcher()
    /// 외부 선택은 세션 없는 앱에 입력기 세션을 만들지 않는다(ADR 0061). 확인이 없으면 사용자의 이전 입력 소스 단축키를 두 번 누른다.
    let sessionRepair: InputMethodSessionRepair
    /// 자동 전환의 "언제·재시도" 판단은 Core에 있다(테스트 대상). 여기서는 실제 TIS와 main queue를 연결한다.
    let autoReset: AutoResetCoordinator
    let router: InputMethodRoutingCoordinator
    private let settings: @MainActor () -> KeyHueSettings
    /// Whether both KeyHue modes were enabled at the last change of the enabled list.
    private var inputMethodWasAvailable = false

    init(memory: AppInputMemory,
         settings: @escaping @MainActor () -> KeyHueSettings,
         serverNeedsUpdate: @escaping @MainActor () -> Bool,
         routingEnabled: @escaping @MainActor () -> Bool) {
        sessionRepair = SystemSessionRepair.make(poster: shortcutPoster, serverNeedsUpdate: serverNeedsUpdate)
        autoReset = AutoResetCoordinator(switcher: switcher, scheduler: MainQueueScheduler(), memory: memory, settings: settings)
        router = InputMethodRoutingCoordinator(switcher: switcher, scheduler: MainQueueScheduler(), isEnabled: routingEnabled)
        self.settings = settings
        switcher.onSelected = { [unowned self] selected, previous in
            self.sessionRepair.selected(sourceID: selected, previousID: previous)
        }
    }

    /// - Parameter suspendRouting: 라우팅이 실패하거나 바로 덮어써졌다. 설정에서 끈다.
    func start(inputSourceMonitor: InputSourceMonitor, suspendRouting: @escaping @MainActor () -> Void) {
        router.reset(current: InputSourceController.current())
        inputMethodWasAvailable = inputMethodAvailable
        router.onRequest = { [weak self] in self?.autoReset.cancelPendingWork() }
        router.onCompletion = { [weak inputSourceMonitor] ok in
            Log.state.notice("input method routing: \(ok ? "ok" : "FAILED")")
            inputSourceMonitor?.refresh()
        }
        router.onSuspend = {
            Log.state.notice("input method routing suspended: selection failed or immediately overwritten")
            suspendRouting()
        }
        inputSourceMonitor.onSelection = { [weak self] source in
            // 복구 단축키 사이의 중간 소스는 사용자의 선택이 아니다.
            guard let self, !self.sessionRepair.isRepairing else { return }
            self.router.sourceChanged(to: source)
        }
        sessionRepair.onRepairStarted = { [weak self] in
            Log.state.notice("input method session not acknowledged; pressing the previous-source shortcut twice")
            self?.autoReset.cancelPendingWork()
        }
        sessionRepair.onFinished = { [weak self, weak inputSourceMonitor] outcome in
            guard let self, outcome != .acknowledged else { return }
            Log.state.notice("input method session repair: \(String(describing: outcome)) now=\(InputSourceController.current()?.id ?? "-")")
            self.router.reset(current: InputSourceController.current())
            inputSourceMonitor?.refresh()
        }
        terminalKeyPostServer.start()
        acknowledgementMonitor.start { [weak self] modeID in
            self?.sessionRepair.acknowledged(modeID: modeID)
        }
        autoReset.onWillSwitch = { [weak self] in
            // Source notifications caused by KeyHue aren't manual toggle requests.
            self?.router.reset(current: nil)
        }
        autoReset.onEvent = { [weak self, weak inputSourceMonitor] event in
            Log.state.notice("auto reset: \(event) now=\(InputSourceController.current()?.id ?? "-")")
            switch event {
            case .switched:
                self?.router.reset(current: InputSourceController.current())
                inputSourceMonitor?.refresh()
            case .retrying, .skipped, .keptManualSwitch: break
            }
        }
    }

    private var inputMethodAvailable: Bool {
        settings().integrateInputMethod && InputMethodIntegration.isAvailable(in: InputSourceController.enabledSources())
    }

    /// 켜진 입력 소스 목록이 바뀌었다.
    func enabledSourcesChanged() {
        // Modes added in System Settings after setup: select them as setup would have,
        // or ⌘Space keeps toggling the system sources the user used before (ADR 0076).
        let available = inputMethodAvailable
        if available, !inputMethodWasAvailable, settings().routeInputMethodPair {
            let selected = InputMethodSetup.selectHangulAfterSetup()
            Log.app.notice("both KeyHue modes enabled; selected English then Korean: \(selected)")
        }
        inputMethodWasAvailable = available
        router.reset(current: InputSourceController.current())
    }

    /// 입력기 설정을 마치려고 다시 실행됐다(`WorkerCommand.finishSetupFlag`).
    func finishSetupAfterRelaunch(inputSourceMonitor: InputSourceMonitor) {
        guard inputMethodAvailable else { return }
        let selected = InputMethodSetup.selectHangulAfterSetup()
        router.reset(current: InputSourceController.current())
        inputSourceMonitor.refresh()
        Log.app.notice("input method setup after relaunch: selected=\(selected) observed=\(InputSourceController.current()?.id ?? "none")")
    }

    /// 전환 방식에 영향을 주는 설정이 바뀌면 기다리던 전환을 버린다.
    func settingsChanged(from old: KeyHueSettings, to new: KeyHueSettings) {
        guard old.integrateInputMethod != new.integrateInputMethod || old.routeInputMethodPair != new.routeInputMethodPair
            || old.defaultSourceID != new.defaultSourceID else { return }
        autoReset.cancelPendingWork()
        router.reset(current: InputSourceController.current())
    }

    /// 앱별·창별 기억: 현재 활성 앱(창)에서 입력 소스가 바뀔 때마다 기록한다. KeyHue의 라우팅 중에는 하지 않는다.
    func sourceChanged(from old: InputSourceInfo?, to new: InputSourceInfo?, activeBundleID: String?, activeWindow: AnyHashable?) {
        guard !router.isPending else { return }
        autoReset.sourceChanged(from: old, to: new, activeBundleID: activeBundleID, activeWindow: activeWindow)
    }

    func windowSwitched(from previous: AnyHashable?, to window: AnyHashable, current: InputSourceInfo?) {
        router.reset(current: InputSourceController.current())
        autoReset.windowSwitched(from: previous, to: window, current: current)
    }

    func focusChanged(wasTextInput: Bool, isTextInput: Bool, current: InputSourceInfo?) {
        router.reset(current: InputSourceController.current())
        autoReset.focusChanged(wasTextInput: wasTextInput, isTextInput: isTextInput, current: current)
    }

    func stop() {
        acknowledgementMonitor.stop()
        terminalKeyPostServer.stop()
    }

    /// 사용자가 키를 눌렀다. 단축키(⌘Space 등)는 입력 소스를 바꿀 수 있다.
    func keyDown(_ key: KeyboardMonitor.KeyDown, current: InputSourceInfo?) {
        sessionRepair.interaction()
        router.interaction(isTyping: !key.otherModifiers)
        // 앱 전환 대기 중이면 단축키 결과를 사용자 선택으로 본다.
        if key.otherModifiers { autoReset.userMayHaveSwitchedSource() }
        autoReset.keyDown(keyCode: key.keyCode, isAutoRepeat: key.isAutoRepeat, current: current)
    }

    /// 클릭: 메뉴 막대 입력 메뉴에서 고를 수 있다.
    func mouseDown() {
        autoReset.userMayHaveSwitchedSource()
        sessionRepair.interaction()
        router.interaction(isTyping: false)
    }
}
