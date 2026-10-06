import AppKit
import KeyHueCore

/// 메뉴 항목의 체크 표시와 색 견본. 메뉴 상태 값(Core)을 AppKit 표현으로 바꾼다.
extension StatusBarController {
    static func menuState(_ status: FeatureStatus) -> NSControl.StateValue {
        stateValue(MenuCheck(status))
    }

    static func stateValue(_ check: MenuCheck) -> NSControl.StateValue {
        switch check {
        case .off: return .off
        case .on: return .on
        case .mixed: return .mixed
        }
    }

    static func swatch(_ color: RGBAColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
