import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    func refreshInputMethodStatus() { model.reload() }
    private let model: SettingsModel
    private var window: NSWindow?

    /// 창이 열리고 닫힐 때. Dock 표시를 끈 상태에서도 열려 있는 동안은 Dock에 보이게 한다(ADR 0038).
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        onVisibilityChange?(true)
        // 창을 닫을 때 포커스를 돌려주려고 앱을 숨긴다(ADR 0038). 숨긴 앱의 창은 앞으로 가져와도 보이지 않으므로 먼저 푼다.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showUpdates() {
        model.selectedTab = .general
        show()
    }

    func showInputMethod() {
        model.selectedTab = .inputMethod
        show()
    }

    func updateTitle() {
        window?.title = L("KeyHue Settings")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = L("KeyHue Settings")
        // 본문 배경을 제목 막대 밑까지 늘려 한 가지 색으로 잇는다. 탭 막대 위에 구분선이나 색 차이가 생기지 않게 한다.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.center()
        // The window is kept and reused, so this observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onVisibilityChange?(false) }
        }
        return window
    }
}
