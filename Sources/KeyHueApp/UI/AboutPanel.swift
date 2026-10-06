import AppKit

/// KeyHue 정보 창. 메뉴바 메뉴와 Dock에 보일 때의 앱 메뉴가 연다.
@MainActor
enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/sejoung/KeyHue")!

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: L("KeyHue never records what you type.") + "\n",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        )
        credits.append(NSAttributedString(
            string: "github.com/sejoung/KeyHue",
            attributes: [.font: font, .link: repositoryURL, .paragraphStyle: paragraph]
        ))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
