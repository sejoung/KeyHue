import KeyHueCore

/// Sends what the key tap and the Accessibility monitor see to the features that
/// use it: automatic switching, the HUD and the wrong-language warning.
@MainActor
final class InputEventRouter {
    private let monitors: FeatureMonitors
    private let switching: InputSwitching
    private let hud: HUDController
    private let currentSource: @MainActor () -> InputSourceInfo?
    private let frontBundleID: @MainActor () -> String?

    init(monitors: FeatureMonitors, switching: InputSwitching, hud: HUDController,
         currentSource: @escaping @MainActor () -> InputSourceInfo?, frontBundleID: @escaping @MainActor () -> String?) {
        self.monitors = monitors
        self.switching = switching
        self.hud = hud
        self.currentSource = currentSource
        self.frontBundleID = frontBundleID
    }

    func start(onWarning: @escaping (MistypeVerdict, Bool) -> Void) {
        monitors.keyboard.onKeyDown = { [weak self] key in
            guard let self else { return }
            // 타이핑을 시작하면 HUD를 바로 숨긴다(어떤 키인지는 보지 않는다, ADR 0025).
            self.hud.hideNow()
            let source = self.currentSource()
            self.switching.keyDown(key, current: source)
            self.monitors.wrongLanguage.key(key, sourceID: source?.id)
        }
        monitors.keyboard.onMouseDown = { [weak self] in
            self?.switching.mouseDown()
            self?.monitors.wrongLanguage.reset()
        }
        monitors.wrongLanguage.onWarning = onWarning
        monitors.focus.onWindowSwitched = { [weak self] previous, window in
            guard let self else { return }
            Log.state.notice("window switched within \(self.frontBundleID() ?? "-")")
            self.switching.windowSwitched(from: previous.map(AnyHashable.init), to: AnyHashable(window), current: self.currentSource())
        }
        monitors.focus.onFocusChanged = { [weak self] wasText, isText in
            guard let self else { return }
            self.switching.focusChanged(wasTextInput: wasText, isTextInput: isText, current: self.currentSource())
        }
    }
}
