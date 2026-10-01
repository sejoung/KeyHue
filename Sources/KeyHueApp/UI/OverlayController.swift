import AppKit
import KeyHueCore

/// 화면 하단 State Bar. 클릭/포커스를 받지 않는 borderless non-activating panel이다.
final class StateBarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // KeyHue를 숨겨도(설정 창을 닫아 메뉴바 전용으로 돌아갈 때의 NSApp.hide, ⌘H, 다른 앱의 "기타 가리기") 막대는 남는다.
        canHide = false
        animationBehavior = .none
        // 메뉴바(.mainMenu)·Dock(.dock) 위, 시스템 alert/화면 보호기보다는 아래.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Screen 탐색, 화면별 Overlay window 관리, 색상/위치 업데이트.
@MainActor
final class OverlayController {
    private(set) var panels: [CGDirectDisplayID: StateBarPanel] = [:]
    private var observers: [NSObjectProtocol] = []

    private var color: NSColor = .clear
    private var thickness: CGFloat = 3
    private var position: BarPosition = .top
    private var isVisible = true
    private var policy: DisplayPolicy = .allScreens
    private var activeDisplayID: CGDirectDisplayID?
    /// 경고 깜빡임 중(ADR 0041). 깜빡임이 끝나기 전에 상태가 바뀌어도 마지막에 지금 색으로 돌아온다.
    private var flashGeneration = 0
    private(set) var isFlashing = false

    /// 깜빡임: 켜짐·꺼짐 길이와 횟수, 그동안의 최소 두께(얇은 막대에서도 보이게).
    static let flashOn: TimeInterval = 0.14
    static let flashOff: TimeInterval = 0.09
    static let flashCount = 3
    static let flashMinimumThickness: CGFloat = 6
    /// 깜빡임 순서. 앱에서는 main queue, 테스트에서는 가짜 시간(ADR 0026).
    private let scheduler: Scheduling

    init(scheduler: Scheduling = MainQueueScheduler()) {
        self.scheduler = scheduler
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        layout()
    }

    func apply(state: InputState, settings: KeyHueSettings) {
        let newColor = NSColor(settings.barColor(for: state))
        let newThickness = CGFloat(settings.barHeight)
        let needsLayout = newThickness != thickness
            || settings.barPosition != position
            || settings.showStateBar != isVisible
            || settings.displayPolicy != policy
        color = newColor
        thickness = newThickness
        position = settings.barPosition
        isVisible = settings.showStateBar
        policy = settings.displayPolicy

        if needsLayout {
            layout()
        } else if !isFlashing {
            panels.values.forEach { $0.backgroundColor = newColor }
        }
    }

    /// 잘못된 언어 경고: 막대를 의도한 언어의 색으로 몇 번 깜빡인다(굵게). 끝나면 지금 상태 색과 두께로 돌아온다.
    /// 막대를 꺼 두었으면 아무것도 하지 않는다(호출자가 HUD로 대신 알린다).
    func flash(color: RGBAColor) {
        guard isVisible else { return }
        flashGeneration += 1
        let generation = flashGeneration
        let flashColor = NSColor(color)
        isFlashing = true
        setThickness(max(thickness, Self.flashMinimumThickness))

        var delay: TimeInterval = 0
        for _ in 0..<Self.flashCount {
            schedule(after: delay, generation) { $0.panels.values.forEach { $0.backgroundColor = flashColor } }
            delay += Self.flashOn
            schedule(after: delay, generation) { overlay in overlay.panels.values.forEach { $0.backgroundColor = overlay.color } }
            delay += Self.flashOff
        }
        schedule(after: delay, generation) { overlay in
            overlay.isFlashing = false
            overlay.setThickness(overlay.thickness)
            overlay.panels.values.forEach { $0.backgroundColor = overlay.color }
        }
    }

    private func schedule(after delay: TimeInterval, _ generation: Int, _ action: @escaping @MainActor (OverlayController) -> Void) {
        let run: @MainActor () -> Void = { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            action(self)
        }
        // 첫 깜빡임은 바로(경고가 늦게 보이지 않게).
        if delay == 0 { run() } else { scheduler.schedule(after: delay, run) }
    }

    /// 패널 두께만 바꾼다(저장된 두께 설정은 그대로).
    private func setThickness(_ value: CGFloat) {
        for (id, panel) in panels {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            panel.setFrame(ScreenGeometry.stateBarFrame(screenFrame: screen.frame, thickness: value, position: position), display: true)
        }
    }

    /// "현재 활성 모니터만 표시" 정책에서 사용할 화면. nil이면 NSScreen.main.
    func setActiveScreen(_ screen: NSScreen?) {
        let id = screen?.displayID
        guard id != activeDisplayID else { return }
        activeDisplayID = id
        if policy == .activeScreen {
            layout()
        }
    }

    /// Space/Full Screen 전환 후 순서가 밀린 경우를 대비해 다시 앞으로 올린다.
    func bringToFront() {
        guard isVisible else { return }
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    private func targetScreens() -> [NSScreen] {
        switch policy {
        case .allScreens:
            return NSScreen.screens
        case .activeScreen:
            let active = NSScreen.screens.first { $0.displayID == activeDisplayID } ?? NSScreen.main
            return active.map { [$0] } ?? []
        }
    }

    private func layout() {
        guard isVisible else {
            panels.values.forEach { $0.orderOut(nil) }
            return
        }

        var remaining = panels
        for screen in targetScreens() {
            guard let id = screen.displayID else { continue }
            let frame = ScreenGeometry.stateBarFrame(screenFrame: screen.frame, thickness: thickness, position: position)
            let panel = remaining.removeValue(forKey: id) ?? StateBarPanel(frame: frame)
            panel.setFrame(frame, display: false)
            panel.backgroundColor = color
            panel.orderFrontRegardless()
            panels[id] = panel
        }
        for (id, panel) in remaining {
            panel.orderOut(nil)
            panel.close()
            panels[id] = nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension NSColor {
    convenience init(_ color: RGBAColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    var rgbaColor: RGBAColor? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return RGBAColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }
}
