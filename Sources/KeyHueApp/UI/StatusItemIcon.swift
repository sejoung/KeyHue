import AppKit
import KeyHueCore

/// 메뉴 막대 아이콘. 카멜레온을 현재 상태색으로 칠한다(카멜레온처럼 색이 바뀐다). 설정이 꺼져 있으면 template.
@MainActor
final class StatusItemIcon {
    /// docs/icon.png에서 추출한 카멜레온 실루엣(alpha mask). 번들 없이 실행하면 nil.
    private let chameleon = ChameleonImage.menuBarMask
    private var renderedKey: String?

    func render(on button: NSStatusBarButton, settings: KeyHueSettings, state: InputState) {
        let color = settings.color(for: state)
        let key = settings.tintMenuBarIcon ? color.hexString : "template"
        guard key != renderedKey else { return }
        renderedKey = key

        guard let chameleon else {
            let fallback = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyHue")
            fallback?.isTemplate = true
            button.image = fallback
            return
        }
        if settings.tintMenuBarIcon {
            let tinted = ChameleonImage.tinted(chameleon, color: color)
            tinted.accessibilityDescription = "KeyHue"
            button.image = tinted
        } else {
            let template = chameleon.copy() as! NSImage
            template.isTemplate = true
            template.accessibilityDescription = "KeyHue"
            button.image = template
        }
    }
}
