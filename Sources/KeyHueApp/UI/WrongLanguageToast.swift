import AppKit
import KeyHueCore

/// 잘못된 언어 경고 메시지(ADR 0041): 화면 아래 가운데에 의도한 언어 색의 카멜레온과 그 언어로 바꾼 단어를 잠깐 보여준다.
///
///     🦎  안녕?        (치는 중에 알리면 그때까지 친 앞부분: 안…?)
///         두벌식(으)로 치려던 건가요?
///
/// - 계속 타이핑해도 바로 숨지 않는다(전환 HUD와 달리, 단어를 읽을 시간이 필요하다). 새 경고가 오면 바로 바꾼다.
/// - 단어는 화면에만 보이고 저장·로그하지 않는다.
/// - 클릭을 받지 않고 포커스를 가져가지 않는다.
@MainActor
final class WrongLanguageToast {
    static let holdDuration: TimeInterval = 1.6
    static let fadeOutDuration: TimeInterval = 0.2
    private static let bottomOffset: CGFloat = 140
    private static let maximumWordLength = 24

    private let mask: NSImage
    private let imageView = NSImageView()
    private let wordLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private lazy var panel = makePanel()
    private let scheduler: Scheduling
    private var generation = 0

    private(set) var isShowing = false

    init(mask: NSImage? = ChameleonImage.hudMask, scheduler: Scheduling = MainQueueScheduler()) {
        self.mask = mask ?? ChameleonImage.fallbackMask
        self.scheduler = scheduler
    }

    /// 표시 중인 글자(테스트용).
    var word: String { wordLabel.stringValue }
    var caption: String { captionLabel.stringValue }
    var frame: NSRect { panel.frame }
    var isPanelVisible: Bool { panel.isVisible }

    /// - word: 의도한 언어로 바꾼 단어(안녕, hello)
    /// - sourceName: 의도한 입력 소스 이름(두벌식, ABC)
    func show(word: String, sourceName: String, color: RGBAColor, on screen: NSScreen?) {
        let shown = word.count > Self.maximumWordLength ? String(word.prefix(Self.maximumWordLength)) + "…" : word
        present(title: shown + "?", caption: L("Meant to type in %@?", sourceName), color: color, on: screen)
    }

    /// A short notice in the same place (ADR 0065): a title and a caption, no typed word.
    func showNotice(title: String, caption: String, color: RGBAColor, on screen: NSScreen?) {
        present(title: title, caption: caption, color: color, on: screen)
    }

    private func present(title: String, caption: String, color: RGBAColor, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        imageView.image = ChameleonImage.tinted(mask, color: color)
        wordLabel.stringValue = title
        captionLabel.stringValue = caption

        let content = panel.contentView!
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setFrame(ScreenGeometry.hudFrame(visibleFrame: screen.visibleFrame, size: size,
                                               bottomOffset: Self.bottomOffset), display: true)

        generation += 1
        let current = generation
        isShowing = true
        // 사라지는 중에 다시 띄우면 진행 중인 페이드 아웃 애니메이션이 alpha를 0으로 끌고 간다. HUD처럼 0초 애니메이션으로 덮는다.
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

    /// 기다리지 않고 바로 숨긴다(사용자가 입력 소스를 바꿔 경고에 반응했을 때. 전환 HUD와 겹치지 않게).
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
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
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
        panel.canHide = false // KeyHue를 숨겨도(NSApp.hide) 표시 중인 메시지가 사라지지 않는다
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        wordLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        wordLabel.lineBreakMode = .byTruncatingTail
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .secondaryLabelColor

        let text = NSStackView(views: [wordLabel, captionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [imageView, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        panel.contentView = background
        return panel
    }
}
