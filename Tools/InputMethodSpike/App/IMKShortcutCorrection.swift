import AppKit
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// ADR 0068: the IMK side of fixes the user asks for with the correction
/// shortcut. `ShortcutCorrector` decides and edits; this adapter recognizes the
/// shortcut and the posted keys in IMK events and logs outcomes, never text.
/// Posting terminal keys goes through KeyHue (ADR 0073).
final class IMKShortcutCorrection {
    private let settings: SpikeCorrectionSettings
    private lazy var corrector = ShortcutCorrector(scheduler: MainQueueScheduler(), keys: SystemTerminalKeys(), report: Self.log)

    init(settings: SpikeCorrectionSettings = .shared) {
        self.settings = settings
    }

    /// Activation and deactivation keep the word: this adapter belongs to one
    /// session, and Ghostty deactivates and reactivates the same session while the
    /// user types (2026-10-06 11:28:48, 11:28:49). Clearing there left nothing to
    /// fix (`cleared=activation keys=0`, ADR 0072). A waiting fix checks
    /// `isCurrent` and the front app itself.
    func activated() {
        settings.start()
    }

    /// Clicks and context changes: the next press is a new request and a
    /// terminal's word before the caret is unknown.
    func interrupt(reason: String = "context") {
        corrector.interrupt(reason: reason)
    }

    func isShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        var modifiers: CorrectionShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return settings.shortcut.matches(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// Every other key, before the session handles it. Never consumes the key.
    /// - Parameters:
    ///   - text: the key's characters; digits and symbols are part of a terminal word.
    ///   - composing: the session had a composition before this key.
    func key(_ route: InputRoute, keyCode: UInt16, modifiers: Bool, shift: Bool = false, text: String?, composing: Bool,
             client: any IMKTextInput, mode: ProbeSession.Mode) {
        corrector.key(route, keyCode: keyCode, modifiers: modifiers, shift: shift, text: text, composing: composing,
                      clientID: client.bundleIdentifier(), mode: mode)
    }

    /// One of the posted Backspaces came back through the input method. The
    /// controller passes it to the client untouched.
    func postedKeyArrived(_ event: NSEvent, modifiers: Bool) -> Bool {
        corrector.postedKeyArrived(
            isBackspace: event.keyCode == KeyCode.delete && !modifiers,
            markerSeen: event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TerminalKeyPost.postedKeyMarker)
    }

    /// The shortcut was pressed. The caller already committed the composition.
    func request(client: any IMKTextInput, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        corrector.request(client: IMKShortcutClient(client), mode: mode, isCurrent: isCurrent)
    }

    private static func log(_ event: ShortcutCorrector.Event) {
        switch event {
        case .lostContext(let byKeys):
            SpikeLog.notice("shortcut correction result=lost-context\(byKeys ? " byKeys=true" : "")")
        case .alreadyWaiting:
            SpikeLog.notice("shortcut correction already waiting byKeys=true")
        case .noTypedWord(let cleared, let keys):
            SpikeLog.notice("shortcut correction no typed word cleared=\(cleared) keys=\(keys) byKeys=true")
        case .expired(let modifiersHeld):
            SpikeLog.notice("shortcut correction result=expired reason=\(modifiersHeld ? "modifiers held" : "marked text") byKeys=true")
        case .keysDelivered(let markerSeen):
            SpikeLog.notice("shortcut correction keys delivered marker=\(markerSeen ? "seen" : "missing")")
        case .keysNotDelivered(let arrived, let erase):
            SpikeLog.notice("shortcut correction result=keys-not-delivered arrived=\(arrived) of=\(erase)")
        case .corrected(let undo):
            SpikeLog.notice("shortcut correction \(undo ? "undo" : "result")=corrected")
        case .correctedByKeys:
            SpikeLog.notice("shortcut correction result=corrected byKeys=true")
        case .failed(let reason, let app):
            SpikeLog.notice("shortcut correction skipped reason=\(reason.rawValue)")
            SpikeCorrectionFeedback.reportFailure(reason, app: app)
        }
    }
}
