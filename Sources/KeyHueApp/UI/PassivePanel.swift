import AppKit

/// 클릭/포커스를 받지 않는 borderless non-activating panel.
/// State Bar, 전환 HUD, 잘못된 언어 경고 메시지가 같은 설정으로 쓴다.
final class PassivePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
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
        // KeyHue를 숨겨도(설정 창을 닫아 메뉴바 전용으로 돌아갈 때의 NSApp.hide, ⌘H, 다른 앱의 "기타 가리기")
        // 막대와 표시 중인 HUD·메시지가 갑자기 사라지지 않는다.
        canHide = false
        animationBehavior = .none
        // 메뉴바(.mainMenu)·Dock(.dock) 위, 시스템 alert/화면 보호기보다는 아래.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
