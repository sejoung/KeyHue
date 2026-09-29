import AppKit
import KeyHueCore

/// 전환 순간 화면 가운데 아래에 카멜레온을 새 입력 소스 색으로 잠깐 보여준다(ADR 0024).
///
/// 언어마다 다른 글자(가/あ/中…) 대신 카멜레온 하나로 모든 입력 소스를 같은 방식으로 표현한다.
/// 색이 곧 입력 소스이므로 State Bar·메뉴바 아이콘과 같은 규칙을 따른다.
@MainActor
final class HUDController {
    /// 전환하는 순간 바로 나타나고(페이드 인 없음), 잠깐 머문 뒤 빠르게 사라진다(ADR 0032).
    /// 서서히 나타나면 색 확인이 그만큼 늦어져 전환 자체가 느리게 느껴진다.
    static let holdDuration: TimeInterval = 0.25
    static let fadeOutDuration: TimeInterval = 0.05
    static let size = NSSize(width: 104, height: 96)
    private static let bottomOffset: CGFloat = 140

    private let mask: NSImage
    private let imageView = NSImageView()
    private lazy var panel = makePanel()
    /// 숨김 예약. 앱에서는 main queue, 테스트에서는 가짜 시간(실제 시간을 기다리는 테스트는 CI에서 흔들린다).
    private let scheduler: Scheduling
    /// 예전 예약이나 늦게 끝난 페이드 아웃이 새로 띄운 HUD를 숨기지 않도록 표시마다 번호를 올린다.
    private var generation = 0

    /// 화면에 보이는 중(페이드 아웃이 시작되면 false).
    private(set) var isShowing = false

    init(mask: NSImage? = ChameleonImage.hudMask, scheduler: Scheduling = MainQueueScheduler()) {
        self.mask = mask ?? ChameleonImage.fallbackMask
        self.scheduler = scheduler
    }

    /// 첫 표시 때 패널을 만드는 비용을 미리 치른다.
    func prepare() {
        _ = panel
    }

    /// 표시 중인 카멜레온 이미지(테스트용).
    var image: NSImage? { imageView.image }

    /// 완전히 보이는 중인지(테스트용). 나타나는 애니메이션 없이 표시하자마자 true여야 한다.
    var isFullyVisible: Bool { isShowing && panel.alphaValue >= 1 }

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
        generation += 1
        let current = generation
        // 애니메이션 없이 바로 보인다. 사라지는 중이었어도 즉시 다시 불투명하게 되돌린다.
        isShowing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        scheduler.schedule(after: Self.holdDuration) { [weak self] in
            self?.fadeOut(current)
        }
    }

    /// 타이핑을 시작하면 기다리지 않고 바로 숨긴다.
    func hideNow() {
        guard isShowing else { return }
        generation += 1
        isShowing = false
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func fadeOut(_ current: Int) {
        guard current == generation else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation, !self.isShowing else { return }
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
