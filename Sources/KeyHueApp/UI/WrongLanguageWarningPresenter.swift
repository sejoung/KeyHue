import AppKit
import KeyHueCore

/// 잘못된 언어 경고와 고침 실패 안내를 보여 준다. HUD와 같은 자리에 뜨므로 HUD를 먼저 숨긴다.
@MainActor
final class WrongLanguageWarningPresenter {
    private let toast = WrongLanguageToast()
    private let hud: HUDController
    private let overlay: OverlayController
    private let settings: @MainActor () -> KeyHueSettings
    /// 메시지를 띄울 화면(포커스가 있는 화면).
    private let screen: @MainActor () -> NSScreen?

    init(hud: HUDController, overlay: OverlayController,
         settings: @escaping @MainActor () -> KeyHueSettings, screen: @escaping @MainActor () -> NSScreen?) {
        self.hud = hud
        self.overlay = overlay
        self.settings = settings
        self.screen = screen
    }

    /// 잘못된 언어 경고: 그 언어의 색으로 막대를 깜빡이고, "메시지로 알리기"가 켜져 있으면 바꾼 단어를 메시지로 띄운다(ADR 0041).
    /// 치는 중에 알렸으면(ADR 0042) 그때까지 친 앞부분에 "…"를 붙인다.
    func show(_ verdict: MistypeVerdict, whileTyping: Bool) {
        let settings = settings()
        let sources = InputSourceController.enabledSources()
        let integrated = settings.integrateInputMethod && InputMethodIntegration.isAvailable(in: sources)
        guard let id = MistypeSupport.intendedSourceID(for: verdict, enabledSourceIDs: sources.map(\.id), integrated: integrated),
              let source = sources.first(where: { $0.id == id }) else { return }
        let word: String
        switch verdict {
        case .keep: return
        case .meantHangul(let text), .meantLatin(let text): word = whileTyping ? text + "…" : text
        }
        let color = settings.color(for: source)
        if settings.wrongLanguageShowsMessage {
            hud.hideNow()
            toast.show(word: word, sourceName: source.displayName, color: color, on: screen())
        }
        overlay.flash(color: color) // 막대를 숨겨 두었으면 아무것도 하지 않는다
    }

    /// 고침 실패 안내(ADR 0065).
    func showNotice(title: String, caption: String) {
        hud.hideNow()
        toast.showNotice(title: title, caption: caption, color: settings().unknownColor, on: screen())
    }

    /// 경고를 보고 입력 소스를 바꿨다: 메시지는 할 일을 다 했다.
    func hideNow() {
        toast.hideNow()
    }
}
