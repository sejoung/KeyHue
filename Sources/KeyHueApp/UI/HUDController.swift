import AppKit
import KeyHueCore

/// (Phase 2) 상태 변경 순간 화면 중앙 하단에 `가 / a / A`를 잠깐 표시한다.
@MainActor
final class HUDController {
    static let displayDuration: TimeInterval = 0.5
    private static let size = NSSize(width: 88, height: 88)
    private static let bottomOffset: CGFloat = 140

    private lazy var panel = makePanel()
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    func show(state: InputState, color: RGBAColor, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }

        label.stringValue = state.hudGlyph
        label.textColor = NSColor(color)

        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + Self.bottomOffset
        )
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 44, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        panel.contentView = background
        return panel
    }
}
