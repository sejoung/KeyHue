import AppKit
import KeyHueCore

/// 잠깐 보였다 사라지는 패널(전환 HUD, 잘못된 언어 경고 메시지)의 표시·유지·페이드 아웃.
///
/// 나타날 때는 애니메이션 없이 바로 보이고, `holdDuration` 뒤 `fadeOutDuration` 동안 사라진다.
/// 패널은 쓰는 쪽이 처음 표시할 때 만들 수 있도록 호출마다 넘겨받는다.
@MainActor
final class TransientPanelPresenter {
    /// 화면 아래 가장자리(Dock 위)에서 패널까지의 거리. HUD와 경고 메시지가 같은 자리에 뜬다.
    static let bottomOffset: CGFloat = 140

    private let holdDuration: TimeInterval
    private let fadeOutDuration: TimeInterval
    /// 숨김 예약. 앱에서는 main queue, 테스트에서는 가짜 시간(실제 시간을 기다리는 테스트는 CI에서 흔들린다).
    private let scheduler: Scheduling
    /// 예전 예약이나 늦게 끝난 페이드 아웃이 새로 띄운 패널을 숨기지 않도록 표시마다 번호를 올린다.
    private var generation = 0

    /// 화면에 보이는 중(페이드 아웃이 시작되면 false).
    private(set) var isShowing = false

    init(holdDuration: TimeInterval, fadeOutDuration: TimeInterval, scheduler: Scheduling) {
        self.holdDuration = holdDuration
        self.fadeOutDuration = fadeOutDuration
        self.scheduler = scheduler
    }

    /// 바로 보이고 유지 시간을 처음부터 다시 잰다.
    func show(_ panel: NSPanel) {
        generation += 1
        let current = generation
        isShowing = true
        // 사라지는 중이었으면 진행 중인 페이드 아웃 애니메이션이 alpha를 0으로 끌고 간다. 0초 애니메이션으로 덮고 즉시 불투명하게 되돌린다.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        scheduler.schedule(after: holdDuration) { [weak self, weak panel] in
            guard let panel else { return }
            self?.fadeOut(panel, current)
        }
    }

    /// 기다리지 않고 바로 숨긴다. 떠 있지 않으면 아무것도 하지 않는다.
    func hideNow(_ panel: NSPanel) {
        guard isShowing else { return }
        generation += 1
        isShowing = false
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func fadeOut(_ panel: NSPanel, _ current: Int) {
        guard current == generation else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, current == self.generation, !self.isShowing else { return }
                panel.orderOut(nil)
            }
        })
    }
}
