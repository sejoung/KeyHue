import Foundation
import KeyHueCore

/// The client as the shortcut correction sees it (ADR 0068): its app, the text
/// around the caret, and edits. Terminals report no text; they get only inserts.
public protocol ShortcutCorrectionClient: AnyObject {
    var bundleID: String? { get }
    var selection: NSRange { get }
    /// The client reports a composition of its own.
    var hasMarkedText: Bool { get }
    func text(in range: NSRange) -> String?
    func replace(_ range: NSRange, with text: String)
    /// Inserts at the caret.
    func insert(_ text: String)
    func select(_ mode: ProbeSession.Mode)
}

/// Delayed main-thread steps and the clock their deadlines use.
public protocol CorrectionScheduling: AnyObject {
    /// Seconds on a monotonic clock (system uptime).
    var now: Double { get }
    /// Runs `work` on the main thread after `delay` seconds; 0: once this main-thread turn is over.
    func schedule(after delay: Double, _ work: @escaping () -> Void)
}

/// ADR 0068: fixes the user asks for with the correction shortcut, in either
/// direction. The selection, or the word before the caret, is read from the
/// client at that moment and re-read as typed on the other layout
/// (`LayoutConversion`); no detector, no tracking that can drop a word. The same
/// shortcut again right away puts the original back.
///
/// Terminals report no text: the word is what was typed since the last boundary
/// (`TypedWord`), erased with posted Backspace keys and the fix inserted after
/// the last one (ADR 0067, `ShortcutCorrector+Keys.swift`).
///
/// Main thread only. Reports outcomes as `Event`s, which carry no text.
public final class ShortcutCorrector {
    public enum Event: Equatable, Sendable {
        /// The user moved on before the fix was made.
        case lostContext(byKeys: Bool)
        /// The shortcut again while a terminal fix waits: it is the same request.
        case alreadyWaiting
        /// A terminal has no typed word: what last emptied it and how many keys arrived since (ADR 0071).
        case noTypedWord(cleared: String, keys: Int)
        /// A terminal fix gave up waiting for released modifiers or a finished composition.
        case expired(modifiersHeld: Bool)
        /// The last posted Backspace came back; `markerSeen`: it carried KeyHue's marker.
        case keysDelivered(markerSeen: Bool)
        case keysNotDelivered(arrived: Int, of: Int)
        /// The client shows the fix, or the original again (`undo`).
        case corrected(undo: Bool)
        case correctedByKeys
        case failed(CorrectionFailure, app: String?)
    }

    static let interval = 0.01
    static let timeout = 0.3
    /// Text read before the caret to find the last word (UTF-16).
    static let readLength = 128
    /// Waits for the client to finish a composition before erasing.
    static let keyTimeout = 1.0
    /// Waits for the shortcut's modifiers to be released (a held ⌥ or ⌘ changes
    /// Backspace). Nothing shows until then, so people keep ⌥ down and tap ↩ again;
    /// a short limit dropped those fixes silently (ADR 0071).
    static let modifierTimeout = 10.0
    /// Posted Backspaces that have not come back by then were not delivered.
    static let deliveryTimeout = 0.5

    let scheduler: any CorrectionScheduling
    let keys: any TerminalKeyPosting
    let report: (Event) -> Void

    var toggle = ShortcutToggle()
    /// Terminals: the word before the caret, from typed keys.
    var typed = TypedWord()
    var posted = PostedBackspaces()
    var pendingFix = PendingKeyFix()
    var pendingInsert: (text: String, client: any ShortcutCorrectionClient)?
    /// Cancels a scheduled step when anything else happens.
    var generation = 0
    /// Diagnostics for an empty terminal word (ADR 0071): what last emptied it and
    /// how many keys arrived since. Names and counts only, never text.
    var lastClear = "none"
    var keysSinceClear = 0

    public init(scheduler: any CorrectionScheduling, keys: any TerminalKeyPosting, report: @escaping (Event) -> Void) {
        self.scheduler = scheduler
        self.keys = keys
        self.report = report
    }

    /// Clicks and context changes: the next press is a new request and a
    /// terminal's word before the caret is unknown.
    public func interrupt(reason: String = "context") {
        lastClear = reason
        keysSinceClear = 0
        generation &+= 1
        pendingFix.end()
        toggle.forget()
        typed.clear()
    }

    /// Every other key, before the session handles it. Never consumes the key.
    /// - Parameters:
    ///   - text: the key's characters; digits and symbols are part of a terminal word.
    ///   - composing: the session had a composition before this key.
    public func key(_ route: InputRoute, keyCode: UInt16, modifiers: Bool, shift: Bool = false, text: String?, composing: Bool,
                    clientID: @autoclosure () -> String?, mode: ProbeSession.Mode) {
        generation &+= 1
        pendingFix.end()
        toggle.forget()
        guard CorrectionRouting.editsWithKeys(clientID: clientID()) else { return }
        keysSinceClear += 1
        switch route {
        case .backspace: typed.backspace(composing: composing)
        case .commitSpace: typed.space()
        case .compose(let key): typed.letter(key, mode: mode)
        case .commitAndPass:
            if !modifiers, let text, TypedWord.isPrinted(text) {
                typed.other(text)
            } else {
                typed.clear()
                // Shift+arrows select in a shell (zsh-shift-select) or a full-screen program (ADR 0078).
                lastClear = shift && !modifiers && (KeyCode.leftArrow...KeyCode.upArrow).contains(keyCode) ? "selection" : "boundary key"
                keysSinceClear = 0
            }
        }
    }

    /// The shortcut was pressed. The caller already committed the composition.
    public func request(client: any ShortcutCorrectionClient, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        if CorrectionRouting.editsWithKeys(clientID: client.bundleID) {
            // ↩ tapped again with ⌥ still held: the waiting fix is this request.
            guard !pendingFix.isWaiting else {
                report(.alreadyWaiting)
                return
            }
            generation &+= 1
            requestWithKeys(client: client, mode: mode, isCurrent: isCurrent)
            return
        }
        generation &+= 1
        let version = generation
        // The commit's own getters can lag; read on the next turn.
        scheduler.schedule(after: Self.interval) { [weak self] in
            guard let self else { return }
            guard version == generation, isCurrent() else {
                report(.lostContext(byKeys: false))
                return
            }
            requestWithRange(client: client, mode: mode, isCurrent: isCurrent)
        }
    }

    func fail(_ reason: CorrectionFailure, _ client: any ShortcutCorrectionClient) {
        report(.failed(reason, app: client.bundleID))
    }

    // MARK: clients that report text

    private func requestWithRange(client: any ShortcutCorrectionClient, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        let selection = client.selection
        guard selection.location != NSNotFound, selection.location >= 0 else { fail(.textUnavailable, client); return }
        if let edit = toggle.takeRepeat() {
            let range = NSRange(location: edit.location, length: edit.replacement.utf16.count)
            if selection == NSRange(location: NSMaxRange(range), length: 0),
               client.text(in: range) == edit.replacement {
                replace(range, with: edit.original, select: edit.previousMode, remember: nil, undo: true,
                        client: client, isCurrent: isCurrent)
                return
            }
        }
        let range: NSRange
        let original: String
        if selection.length > 0 {
            guard let text = client.text(in: selection), text.utf16.count == selection.length else {
                fail(.textUnavailable, client); return
            }
            range = selection
            original = text
        } else {
            let start = max(0, selection.location - Self.readLength)
            let before: String
            if selection.location == 0 {
                before = ""
            } else {
                guard let text = client.text(in: NSRange(location: start, length: selection.location - start)),
                      text.utf16.count == selection.location - start else { fail(.textUnavailable, client); return }
                before = text
            }
            guard let word = LayoutConversion.lastWord(in: before, reachesStart: start == 0) else { fail(.nothingToFix, client); return }
            range = NSRange(location: start + word.offset, length: (word.word + word.trailing).utf16.count)
            original = word.word + word.trailing
        }
        guard let target = LayoutConversion.target(of: original) else { fail(.nothingToFix, client); return }
        let replacement = LayoutConversion.convert(original, to: target)
        guard replacement != original else { fail(.nothingToFix, client); return }
        let edit = ShortcutToggle.Edit(location: range.location, original: original, replacement: replacement, previousMode: mode)
        replace(range, with: replacement, select: target, remember: edit, undo: false, client: client, isCurrent: isCurrent)
    }

    /// Replaces, selects the mode and confirms what the client shows.
    private func replace(_ range: NSRange, with text: String, select mode: ProbeSession.Mode, remember edit: ShortcutToggle.Edit?,
                         undo: Bool, client: any ShortcutCorrectionClient, isCurrent: @escaping () -> Bool) {
        let original = client.text(in: range)
        client.replace(range, with: text)
        client.select(mode)
        if let edit { toggle.remember(edit) }
        let version = generation
        let deadline = scheduler.now + Self.timeout
        let result = NSRange(location: range.location, length: text.utf16.count)
        func observe() {
            // The user typed on or moved away: what they see is theirs now.
            guard version == generation, isCurrent() else { return }
            if client.text(in: result) == text {
                report(.corrected(undo: undo))
                return
            }
            guard scheduler.now < deadline else {
                toggle.forget()
                let shown = client.text(in: range)
                if let failure = CorrectionResultCheck.failure(afterRequest: true, textAvailable: original != nil && shown != nil,
                                                               originalStillThere: shown == original) {
                    fail(failure, client)
                }
                return
            }
            scheduler.schedule(after: Self.interval, observe)
        }
        scheduler.schedule(after: Self.interval, observe)
    }
}
