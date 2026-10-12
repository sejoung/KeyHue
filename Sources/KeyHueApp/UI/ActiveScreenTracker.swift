import AppKit
import KeyHueCore

/// The screen of the active app, for the bar on the active screen, the HUD and the
/// warning message (ADR 0024, 0063). Found only while a setting follows it.
@MainActor
final class ActiveScreenTracker {
    private let overlay: OverlayController
    private let settings: @MainActor () -> KeyHueSettings
    private let frontPID: @MainActor () -> pid_t?
    private var activeAppScreen: NSScreen?

    init(overlay: OverlayController, settings: @escaping @MainActor () -> KeyHueSettings,
         frontPID: @escaping @MainActor () -> pid_t?) {
        self.overlay = overlay
        self.settings = settings
        self.frontPID = frontPID
    }

    /// 모니터를 꽂거나 빼면 HUD·경고 메시지를 띄울 화면을 다시 구한다(빠진 모니터에 띄우지 않게).
    /// The tracker lives as long as the app, so this observer is never removed.
    func start() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// The screen with keyboard focus, found when it is shown. The window list is not read (ADR 0024, 0063).
    var focusedScreen: NSScreen? {
        ActiveScreenLocator.focusedScreen(activeAppScreen: activeAppScreen)
    }

    /// App switch, Space change, setting change.
    func update() {
        guard settings().followsActiveScreen else {
            // 따라가지 않는 동안의 값은 낡는다(모니터를 뺐을 수도 있다). 다시 켜면 새로 구한다.
            activeAppScreen = nil
            return
        }
        activeAppScreen = ActiveScreenLocator.screen(forPID: frontPID())
        overlay.setActiveScreen(focusedScreen)
    }

    /// 포커스가 다른 모니터로 옮겨졌다(같은 앱의 다른 모니터 창 포함, ADR 0063). 창 목록은 조회하지 않는다.
    func displayChanged() {
        guard settings().followsActiveScreen else { return }
        overlay.setActiveScreen(focusedScreen)
    }
}
