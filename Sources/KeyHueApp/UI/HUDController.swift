import AppKit
import KeyHueCore

/// 전환 순간 화면 가운데 아래에 카멜레온을 새 입력 소스 색으로 잠깐 보여준다(ADR 0024).
///
/// 언어마다 다른 글자(가/あ/中…) 대신 카멜레온 하나로 모든 입력 소스를 같은 방식으로 표현한다.
/// 색이 곧 입력 소스이므로 State Bar·메뉴바 아이콘과 같은 규칙을 따른다.
@MainActor
final class HUDController {
    /// 짧게 보였다가 빨리 사라진다(전: 0.5초 + 0.15초 페이드).
    static let displayDuration: TimeInterval = 0.35
    static let fadeDuration: TimeInterval = 0.12
    static let size = NSSize(width: 104, height: 96)
    private static let bottomOffset: CGFloat = 140

    private let mask: NSImage
    private let imageView = NSImageView()
    private lazy var panel = makePanel()
    private var hideWorkItem: DispatchWorkItem?

    init(mask: NSImage? = ChameleonImage.hudMask) {
        self.mask = mask ?? ChameleonImage.fallbackMask
    }

    /// 첫 표시 때 패널을 만드는 비용을 미리 치른다.
    func prepare() {
        _ = panel
    }

    var isShowing: Bool {
        panel.isVisible && panel.alphaValue > 0
    }

    /// 표시 중인 카멜레온 이미지(테스트용).
    var image: NSImage? { imageView.image }

    /// 문서용 스크린샷(DocScreenshots)에서 HUD 모양을 그릴 때 쓴다.
    var contentView: NSView? { panel.contentView }

    func show(color: RGBAColor, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }

        imageView.image = ChameleonImage.tinted(mask, color: color)
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + Self.bottomOffset
        ))
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
            context.duration = Self.fadeDuration
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
            defer: false
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
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 70),
            imageView.heightAnchor.constraint(equalToConstant: 64)
        ])

        panel.contentView = background
        return panel
    }
}
