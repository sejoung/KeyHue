import AppKit
import InputMethodKit
import KeyHueInputMethodSpikeCore

/// ADR 0064 manual correction with the real detector, for the dedicated
/// manual-probe test client only. Normal apps never enter this path until each
/// app's replacement capability is verified (step 5). The decisions are
/// `CorrectionPolicy`'s; this adapter verifies the client's text before every
/// edit and logs outcomes and reasons, never text or keys.
final class IMKManualCorrection {
    static let clientBundleID = "io.github.sejoung.keyhue.testclient.manual-probe"
    private static let interval = 0.01
    private static let timeout = 0.3

    private var policy = CorrectionPolicy(judge: SpikeCorrectionJudge.shared)
    private let environment = CorrectionEnvironment(mode: .manual)
    /// Cancels a scheduled observation when anything else happens.
    private var generation = 0

    static func applies(to client: (any IMKTextInput)?) -> Bool {
        client?.bundleIdentifier() == clientBundleID
    }

    func activated() {
        SpikeCorrectionJudge.shared.load()
        interrupt(.contextChanged)
    }

    func interrupt(_ interruption: CorrectionInterruption) {
        generation &+= 1
        policy.interrupt(interruption)
    }

    /// Returns true when the key was consumed (immediate undo only).
    func key(_ route: InputRoute, keyCode: UInt16, modifiers: Bool, client: any IMKTextInput,
             mode: ProbeSession.Mode) -> Bool {
        generation &+= 1
        switch keyCode {
        case 51 where !modifiers:
            return handle(policy.backspace(), source: "backspace", client: client)
        case 49 where !modifiers:
            guard let caret = caret(client) else { policy.interrupt(.cursorMoved); return false }
            _ = handle(policy.space(caret: caret, mode: mode, environment: environment), source: "space", client: client)
            return false
        case 36: policy.interrupt(.returnKey); return false
        case 48: policy.interrupt(.tab); return false
        case 123...126: policy.interrupt(.cursorMoved); return false
        default: break
        }
        guard case .compose(let key) = route, !modifiers else { policy.interrupt(.otherKey); return false }
        guard let caret = caret(client) else { policy.interrupt(.cursorMoved); return false }
        var atWordStart = false
        if !policy.isTrackingWord {
            let before = caret > 0 ? client.attributedSubstring(from: NSRange(location: caret - 1, length: 1))?.string : nil
            atWordStart = caret == 0 || before == " " || before == "\n" || before == "\t"
        }
        _ = policy.letter(key, caret: caret, atWordStart: atWordStart, mode: mode, environment: environment)
        return false
    }

    /// A mode change reached this session (mode callback or selection notification).
    func signal(_ source: String, target: ProbeSession.Mode?, client: any IMKTextInput,
                isCurrent: @escaping () -> Bool) {
        let decision = policy.modeSignal(to: target, environment: environment)
        guard case .correct(let edit, _) = decision else {
            _ = handle(decision, source: source, client: client)
            return
        }
        SpikeLog.notice("manual correction decided source=\(source) originalLength=\(edit.original.utf16.count)")
        generation &+= 1
        let version = generation
        let clientID = ObjectIdentifier(client as AnyObject)
        let deadline = ProcessInfo.processInfo.systemUptime + Self.timeout
        var requested = false
        var lastReason = "not observed"
        // The signal's own getters can return pre-switch state; observe on later turns.
        func observe() {
            guard version == generation else { return }
            guard isCurrent(), ObjectIdentifier(client as AnyObject) == clientID else {
                SpikeLog.notice("manual correction result=lost-context afterRequest=\(requested)")
                policy.interrupt(.contextChanged); return
            }
            let target = requested ? edit.replacement : edit.original
            let range = NSRange(location: edit.location, length: target.utf16.count)
            if hasMarkedText(client) { lastReason = "marked text" }
            else if client.selectedRange() != NSRange(location: NSMaxRange(range), length: 0) { lastReason = "caret not at word end" }
            else if client.attributedSubstring(from: range)?.string != target {
                lastReason = requested ? "replacement not visible" : "original changed"
            } else if !requested {
                requested = true
                client.insertText(edit.replacement, replacementRange: range)
            } else {
                SpikeLog.notice("manual correction result=corrected")
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                SpikeLog.notice("manual correction result=expired reason=\(lastReason) afterRequest=\(requested)")
                policy.interrupt(.externalEdit); return
            }
            schedule(observe)
        }
        schedule(observe)
    }

    private func handle(_ decision: CorrectionDecision, source: String, client: any IMKTextInput) -> Bool {
        switch decision {
        case .none, .correct:
            return false
        case .skipped(let reason):
            SpikeLog.notice("manual correction skipped source=\(source) reason=\(reason.logName)")
            return false
        case .undo(let edit, let selectLatin):
            // Backspace can arrive before the correction was observed: check what is visible.
            let range = NSRange(location: edit.location, length: edit.replacement.utf16.count)
            guard !hasMarkedText(client), client.selectedRange() == NSRange(location: NSMaxRange(range), length: 0),
                  client.attributedSubstring(from: range)?.string == edit.replacement else {
                SpikeLog.notice("manual correction undo skipped: result not visible")
                return false
            }
            client.insertText(edit.original, replacementRange: range)
            if selectLatin { client.selectMode(SpikeMetadata.latinID) }
            SpikeLog.notice("manual correction undo requested")
            return true
        }
    }

    private func caret(_ client: any IMKTextInput) -> Int? {
        CorrectionProbe.typingCaret(selection: client.selectedRange(), markedRange: client.markedRange())
    }

    private func hasMarkedText(_ client: any IMKTextInput) -> Bool {
        let marked = client.markedRange()
        return marked.location != NSNotFound && marked.length > 0
    }

    /// Same main-queue work item pattern as the automatic correction probe.
    private func schedule(_ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interval, execute: DispatchWorkItem(block: body))
    }
}
