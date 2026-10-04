import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// ADR 0064 manual correction with the real detector, for clients that
/// `CorrectionRouting` routes to manual mode. The decisions are
/// `CorrectionPolicy`'s; this adapter verifies the client's text before every
/// edit and logs outcomes and reasons, never text or keys.
///
/// ADR 0067: terminals report no text positions and send typed text to their
/// program at once. There the word is tracked by keys alone, erased with posted
/// Backspace keys and the fix inserted after the last one. Posting keys needs
/// this input method's own Accessibility access.
final class IMKManualCorrection {
    private static let interval = 0.01
    private static let timeout = 0.3
    /// Waits for the switch shortcut's modifiers to be released (⌘Space).
    private static let keyTimeout = 1.0
    /// Posted Backspaces that have not come back by then were not delivered.
    private static let deliveryTimeout = 0.5
    /// Marks the posted keys (diagnostics only: recognition is by count).
    private static let postedKeyMarker: Int64 = 0x4B48_5545

    /// Terminals (ADR 0067): the posted Backspaces on their way, the text to insert after them.
    private var posted = PostedBackspaces()
    private var pendingInsert: (text: String, client: any IMKTextInput, undo: Bool)?
    /// Terminals: the next letter starts a word (after activation, Space or Return).
    private var atKeyBoundary = true
    private var askedForKeyPermission = false

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
        atKeyBoundary = true
    }

    func interrupt(_ interruption: CorrectionInterruption) {
        generation &+= 1
        policy.interrupt(interruption)
        atKeyBoundary = false
    }

    /// One of this adapter's posted Backspaces came back through the input method.
    /// The controller passes it to the client untouched. After the last one, the
    /// fix is inserted once the client has handled it.
    func postedKeyArrived(_ event: NSEvent, modifiers: Bool) -> Bool {
        guard posted.isPending else { return false }
        let arrival = posted.arrived(isBackspace: event.keyCode == 51 && !modifiers)
        guard arrival != .notOurs else { return false }
        if arrival == .passThroughLast {
            let marked = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.postedKeyMarker
            SpikeLog.notice("manual correction keys delivered marker=\(marked ? "seen" : "missing")")
            // Same main-queue work item pattern as the correction probes.
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                guard let self, Thread.isMainThread else { return }
                self.insertAfterPostedKeys()
            })
        }
        return true
    }

    /// Returns true when the key was consumed (immediate undo only).
    func key(_ route: InputRoute, keyCode: UInt16, modifiers: Bool, client: any IMKTextInput,
             mode: ProbeSession.Mode) -> Bool {
        generation &+= 1
        let byKeys = CorrectionRouting.editsWithKeys(clientID: client.bundleIdentifier())
        let wasAtBoundary = atKeyBoundary
        atKeyBoundary = false
        switch keyCode {
        case 51 where !modifiers:
            return handle(policy.backspace(), source: "backspace", client: client)
        case 49 where !modifiers:
            atKeyBoundary = true
            let caret = byKeys ? nil : caret(client)
            guard byKeys || caret != nil else { policy.interrupt(.cursorMoved); return false }
            _ = handle(policy.space(caret: caret, mode: mode, environment: environment(client)), source: "space", client: client)
            return false
        case 36: policy.interrupt(.returnKey); atKeyBoundary = true; return false
        case 48: policy.interrupt(.tab); return false
        case 123...126: policy.interrupt(.cursorMoved); return false
        default: break
        }
        guard case .compose(let key) = route, !modifiers else { policy.interrupt(.otherKey); return false }
        if byKeys {
            _ = policy.letter(key, caret: nil, atWordStart: wasAtBoundary, mode: mode, environment: environment(client))
            return false
        }
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
        if CorrectionRouting.editsWithKeys(clientID: client.bundleIdentifier()) {
            replaceWithKeys(KeyReplacement(correcting: edit), undo: false, client: client, isCurrent: isCurrent)
            return
        }
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
        case .undo(let edit, _) where CorrectionRouting.editsWithKeys(clientID: client.bundleIdentifier()):
            // A terminal shows nothing to check; the user's Backspace is consumed and ours erase.
            replaceWithKeys(KeyReplacement(undoing: edit), undo: true, client: client, isCurrent: { true })
            recordUndone(edit, client: client)
            return true
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
            recordUndone(edit, client: client)
            return true
        }
    }

    private func recordUndone(_ edit: CorrectionEdit, client: any IMKTextInput) {
        SpikeCorrectionFeedback.recordUndone(original: edit.original.trimmingCharacters(in: .whitespaces),
                                             corrected: edit.replacement.trimmingCharacters(in: .whitespaces),
                                             mode: .manual, client: client)
    }

    // MARK: terminals (ADR 0067)

    /// Erases with posted Backspaces, then inserts. Keys go only to the client's
    /// own process while it is in front, and only once the switch shortcut's
    /// modifiers are released (a held ⌘ would turn Backspace into ⌘Backspace).
    private func replaceWithKeys(_ replacement: KeyReplacement, undo: Bool, client: any IMKTextInput,
                                 isCurrent: @escaping () -> Bool) {
        generation &+= 1
        let version = generation
        let clientID = ObjectIdentifier(client as AnyObject)
        let deadline = ProcessInfo.processInfo.systemUptime + Self.keyTimeout
        let label = undo ? "undo" : "result"
        func attempt() {
            guard version == generation else { return } // the user typed on: the word stays as typed
            guard isCurrent(), ObjectIdentifier(client as AnyObject) == clientID,
                  let front = MainActor.assumeIsolated({ NSWorkspace.shared.frontmostApplication }),
                  let clientApp = client.bundleIdentifier(), front.bundleIdentifier == clientApp else {
                SpikeLog.notice("manual correction \(label)=lost-context byKeys=true")
                policy.interrupt(.contextChanged); return
            }
            guard CGPreflightPostEventAccess() else {
                SpikeLog.notice("manual correction \(label)=skipped reason=keyPermission")
                policy.interrupt(.externalEdit)
                if !askedForKeyPermission {
                    askedForKeyPermission = true
                    _ = CGRequestPostEventAccess() // macOS asks the user once
                }
                SpikeCorrectionFeedback.reportFailure(.keyPermission, client: client)
                return
            }
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
            if !held.isEmpty || hasMarkedText(client) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    SpikeLog.notice("manual correction \(label)=expired reason=\(held.isEmpty ? "marked text" : "modifiers held") byKeys=true")
                    policy.interrupt(.externalEdit); return
                }
                schedule(attempt); return
            }
            pendingInsert = (replacement.insert, client, undo)
            posted.post(replacement.erase)
            let source = CGEventSource(stateID: .privateState)
            for _ in 0..<replacement.erase {
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUserData, value: Self.postedKeyMarker)
                    event.postToPid(front.processIdentifier)
                }
            }
            if replacement.erase == 0 { insertAfterPostedKeys(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.deliveryTimeout, execute: DispatchWorkItem { [weak self] in
                guard let self, Thread.isMainThread, self.posted.isPending else { return }
                let arrived = self.posted.abandon()
                SpikeLog.notice("manual correction \(label)=keys-not-delivered arrived=\(arrived) of=\(replacement.erase)")
                // Some characters are gone already: insert the fix rather than leave a fragment.
                if arrived > 0 { self.insertAfterPostedKeys() } else { self.pendingInsert = nil }
            })
        }
        schedule(attempt)
    }

    private func insertAfterPostedKeys() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        pending.client.insertText(pending.text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        SpikeLog.notice(pending.undo ? "manual correction undo requested byKeys=true" : "manual correction result=corrected byKeys=true")
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
