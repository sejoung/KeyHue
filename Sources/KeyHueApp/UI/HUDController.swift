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
    static let bottomOffset = TransientPanelPresenter.bottomOffset
    /// 배경 모서리와 가운데 카멜레온 크기. 문서용 이미지(DocScreenshots)도 같은 값으로 그린다.
    static let cornerRadius: CGFloat = 20
    static let imageSize = NSSize(width: 70, height: 64)

    private let mask: NSImage
    private let imageView = NSImageView()
    private lazy var panel = makePanel()
    private let presenter: TransientPanelPresenter

    /// 화면에 보이는 중(페이드 아웃이 시작되면 false).
    var isShowing: Bool { presenter.isShowing }

    init(mask: NSImage? = ChameleonImage.hudMask, scheduler: Scheduling = MainQueueScheduler()) {
        self.mask = mask ?? ChameleonImage.fallbackMask
        presenter = TransientPanelPresenter(holdDuration: Self.holdDuration, fadeOutDuration: Self.fadeOutDuration,
                                            scheduler: scheduler)
    }

    /// 첫 표시 때 패널을 만드는 비용을 미리 치른다.
    func prepare() {
        _ = panel
    }

    /// 표시 중인 카멜레온 이미지(테스트용).
    var image: NSImage? { imageView.image }

    /// 패널 창이 화면에 올라가 있는지(테스트용).
    var isPanelVisible: Bool { panel.isVisible }

    /// 완전히 보이는 중인지(테스트용). 나타나는 애니메이션 없이 표시하자마자 true여야 한다.
    var isFullyVisible: Bool { isShowing && panel.alphaValue >= 1 }

    /// 패널 위치(테스트용).
    var panelFrame: NSRect { panel.frame }

    func show(color: RGBAColor, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }

        imageView.image = ChameleonImage.tinted(mask, color: color)
        panel.setFrame(ScreenGeometry.hudFrame(visibleFrame: screen.visibleFrame, size: Self.size,
                                               bottomOffset: Self.bottomOffset), display: false)
        // 애니메이션 없이 바로 보인다. 사라지는 중이었어도 즉시 다시 불투명하게 되돌린다.
        presenter.show(panel)
    }

    /// For the log: whether the HUD is up and on which display.
    var diagnostics: String {
        isShowing ? "shown@\(panel.screen?.displayID.map(String.init) ?? "-")" : "hidden"
    }

    /// 타이핑을 시작하면 기다리지 않고 바로 숨긴다.
    func hideNow() {
        presenter.hideNow(panel)
    }

    private func makePanel() -> PassivePanel {
        let panel = PassivePanel(contentRect: NSRect(origin: .zero, size: Self.size))
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: Self.imageSize.width),
            imageView.heightAnchor.constraint(equalToConstant: Self.imageSize.height)
        ])

        panel.contentView = background
        return panel
    }
}
