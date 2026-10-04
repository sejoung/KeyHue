import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// ADR 0064 manual correction with the real detector, for clients that
/// `CorrectionRouting` routes to manual mode (test client, verified apps). The decisions are
/// `CorrectionPolicy`'s; this adapter verifies the client's text before every
/// edit and logs outcomes and reasons, never text or keys.
final class IMKManualCorrection {
    private static let interval = 0.01
    private static let timeout = 0.3

    private var policy = CorrectionPolicy(judge: SpikeCorrectionJudge.shared)

    /// This adapter serves the manual route; secure input is checked on every decision.
    private func environment(_ client: any IMKTextInput) -> CorrectionEnvironment {
        var environment = CorrectionEnvironment(mode: .manual)
        environment.secureInput = IsSecureEventInputEnabled()
        environment.appExcluded = SpikeCorrectionSettings.shared.excludedApps.contains(client.bundleIdentifier() ?? "")
        environment.ignoredWords = SpikeCorrectionSettings.shared.ignoredWords
        return environment
    }
    /// Cancels a scheduled observation when anything else happens.
    private var generation = 0

    func activated() {
        SpikeCorrectionSettings.shared.start()
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
            _ = handle(policy.space(caret: caret, mode: mode, environment: environment(client)), source: "space", client: client)
            return false
        case 36: policy.interrupt(.returnKey); return false
        case 48: policy.interrupt(.tab); return false
        case 123...126: policy.interrupt(.cursorMoved); return false
        default: break
        }
        guard case .compose(let key) = route, !modifiers else { policy.interrupt(.otherKey); return false }
        guard let caret = caret(client) else { policy.interrupt(.cursorMoved); return false }
        _ = policy.letter(key, caret: caret, atWordStart: Self.isWordStart(caret, client), mode: mode, environment: environment(client))
        return false
    }

    /// A mode change reached this session (mode callback or selection notification).
    func signal(_ source: String, target: ProbeSession.Mode?, client: any IMKTextInput,
                isCurrent: @escaping () -> Bool) {
        let decision = policy.modeSignal(to: target, environment: environment(client))
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
        var textAvailable = true
        // The signal's own getters can return pre-switch state; observe on later turns.
        func observe() {
            guard version == generation else { return }
            guard isCurrent(), ObjectIdentifier(client as AnyObject) == clientID else {
                SpikeLog.notice("manual correction result=lost-context afterRequest=\(requested)")
                policy.interrupt(.contextChanged); return
            }
            let target = requested ? edit.replacement : edit.original
            let range = NSRange(location: edit.location, length: target.utf16.count)
            let visible = client.attributedSubstring(from: range)?.string
            textAvailable = visible != nil
            if hasMarkedText(client) { lastReason = "marked text" }
            else if client.selectedRange() != NSRange(location: NSMaxRange(range), length: 0) { lastReason = "caret not at word end" }
            else if visible != target {
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
                policy.interrupt(.externalEdit)
                let originalRange = NSRange(location: edit.location, length: edit.original.utf16.count)
                let originalStillThere = client.attributedSubstring(from: originalRange)?.string == edit.original
                if let failure = CorrectionResultCheck.failure(afterRequest: requested, textAvailable: textAvailable,
                                                               originalStillThere: originalStillThere) {
                    SpikeCorrectionFeedback.reportFailure(failure, client: client)
                }
                return
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
            SpikeCorrectionFeedback.recordUndone(original: edit.original.trimmingCharacters(in: .whitespaces),
                                                 corrected: edit.replacement.trimmingCharacters(in: .whitespaces),
                                                 mode: .manual, client: client)
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

    /// Document start or after whitespace. One client query; the policy asks only when needed.
    private static func isWordStart(_ caret: Int, _ client: any IMKTextInput) -> Bool {
        guard caret > 0 else { return true }
        let before = client.attributedSubstring(from: NSRange(location: caret - 1, length: 1))?.string
        return before == " " || before == "\n" || before == "\t"
    }
}
