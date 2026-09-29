import AppKit
import KeyHueCore

/// 앱 아이콘에서 추출한 카멜레온 실루엣(scripts/make-menubar-icon.swift)을 상태색으로 칠한다.
/// 메뉴바 아이콘(18pt)과 전환 HUD(64pt)가 같은 모양을 쓴다(ADR 0011, 0024).
@MainActor
enum ChameleonImage {
    /// 번들 없이 실행하면(swift run, 테스트) nil.
    static let menuBarMask = Bundle.main.image(forResource: "MenuBarIcon")
    static let hudMask = Bundle.main.image(forResource: "HUDIcon")

    /// 실루엣이 없을 때 쓰는 대체 모양.
    static var fallbackMask: NSImage {
        NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyHue") ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    static func tinted(_ mask: NSImage, color: RGBAColor) -> NSImage {
        let image = NSImage(size: mask.size, flipped: false) { rect in
            mask.draw(in: rect)
            NSColor(color).setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }
}
