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
    private var panels: [CGDirectDisplayID: StateBarPanel] = [:]
    private var observers: [NSObjectProtocol] = []

    private var color: NSColor = .clear
    private var thickness: CGFloat = 3
    private var position: BarPosition = .top
    private var isVisible = true
    private var policy: DisplayPolicy = .allScreens
    private var activeDisplayID: CGDirectDisplayID?

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
        } else {
            panels.values.forEach { $0.backgroundColor = newColor }
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
