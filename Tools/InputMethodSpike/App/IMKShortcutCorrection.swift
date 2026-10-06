import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// ADR 0068: fixes the user asks for with the correction shortcut, in either
/// direction. The selection, or the word before the caret, is read from the
/// client at that moment and re-read as typed on the other layout
/// (`LayoutConversion`); no detector, no tracking that can drop a word. The same
/// shortcut again right away puts the original back. Logs outcomes, never text.
///
/// Terminals report no text: the word is what was typed since the last boundary
/// (`TypedWord`), erased with posted Backspace keys and the fix inserted after
/// the last one (ADR 0067). Posting keys needs this input method's own
/// Accessibility access.
final class IMKShortcutCorrection {
    private static let interval = 0.01
    private static let timeout = 0.3
    /// Text read before the caret to find the last word (UTF-16).
    private static let readLength = 128
    /// Waits for the client to finish a composition before erasing.
    private static let keyTimeout = 1.0
    /// Waits for the shortcut's modifiers to be released (a held ⌥ or ⌘ changes
    /// Backspace). Nothing shows until then, so people keep ⌥ down and tap ↩ again;
    /// a short limit dropped those fixes silently (ADR 0071).
    private static let modifierTimeout = 10.0
    /// Posted Backspaces that have not come back by then were not delivered.
    private static let deliveryTimeout = 0.5
    /// Marks the posted keys (diagnostics only: recognition is by count).
    private static let postedKeyMarker: Int64 = 0x4B48_5545

    private var toggle = ShortcutToggle()
    /// Terminals: the word before the caret, from typed keys.
    private var typed = TypedWord()
    private var posted = PostedBackspaces()
    private var pendingFix = PendingKeyFix()
    private var pendingInsert: (text: String, client: any IMKTextInput)?
    /// Cancels a scheduled step when anything else happens.
    private var generation = 0
    private var askedForKeyPermission = false
    /// Diagnostics for an empty terminal word (ADR 0071): what last emptied it and
    /// how many keys arrived since. Names and counts only, never text.
    private var lastClear = "none"
    private var keysSinceClear = 0

    func activated() {
        SpikeCorrectionSettings.shared.start()
        interrupt(reason: "activation")
    }

    /// Clicks and context changes: the next press is a new request and a
    /// terminal's word before the caret is unknown.
    func interrupt(reason: String = "context") {
        lastClear = reason
        keysSinceClear = 0
        generation &+= 1
        pendingFix.end()
        toggle.forget()
        typed.clear()
    }

    func isShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        var modifiers: CorrectionShortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return SpikeCorrectionSettings.shared.shortcut.matches(keyCode: event.keyCode, modifiers: modifiers)
    }

    /// Every other key, before the session handles it. Never consumes the key.
    /// - Parameters:
    ///   - text: the key's characters; digits and symbols are part of a terminal word.
    ///   - composing: the session had a composition before this key.
    func key(_ route: InputRoute, keyCode: UInt16, modifiers: Bool, text: String?, composing: Bool,
             client: any IMKTextInput, mode: ProbeSession.Mode) {
        generation &+= 1
        pendingFix.end()
        toggle.forget()
        guard CorrectionRouting.editsWithKeys(clientID: client.bundleIdentifier()) else { return }
        keysSinceClear += 1
        switch keyCode {
        case 51 where !modifiers: typed.backspace(composing: composing)
        case 49 where !modifiers: typed.space()
        default:
            if case .compose(let key) = route, !modifiers {
                typed.letter(key, mode: mode)
            } else if !modifiers, let text, TypedWord.isPrinted(text) {
                typed.other(text)
            } else {
                typed.clear()
                lastClear = "boundary key"
                keysSinceClear = 0
            }
        }
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
            SpikeLog.notice("shortcut correction keys delivered marker=\(marked ? "seen" : "missing")")
            // Same main-queue work item pattern as the correction probes.
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                guard let self, Thread.isMainThread else { return }
                self.insertAfterPostedKeys()
            })
        }
        return true
    }

    /// The shortcut was pressed. The caller already committed the composition.
    func request(client: any IMKTextInput, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        if CorrectionRouting.editsWithKeys(clientID: client.bundleIdentifier()) {
            // ↩ tapped again with ⌥ still held: the waiting fix is this request.
            guard !pendingFix.isWaiting else {
                SpikeLog.notice("shortcut correction already waiting byKeys=true")
                return
            }
            generation &+= 1
            requestWithKeys(client: client, mode: mode, isCurrent: isCurrent)
            return
        }
        generation &+= 1
        let version = generation
        // The commit's own getters can lag; read on the next turn.
        schedule { [self] in
            guard version == generation, isCurrent() else {
                SpikeLog.notice("shortcut correction result=lost-context")
                return
            }
            requestWithRange(client: client, mode: mode, isCurrent: isCurrent)
        }
    }

    // MARK: clients that report text

    private func requestWithRange(client: any IMKTextInput, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location >= 0 else { fail(.textUnavailable, client); return }
        if let edit = toggle.takeRepeat() {
            let range = NSRange(location: edit.location, length: edit.replacement.utf16.count)
            if selection == NSRange(location: NSMaxRange(range), length: 0),
               client.attributedSubstring(from: range)?.string == edit.replacement {
                replace(range, with: edit.original, select: edit.previousMode, remember: nil, label: "undo",
                        client: client, isCurrent: isCurrent)
                return
            }
        }
        let range: NSRange
        let original: String
        if selection.length > 0 {
            guard let text = client.attributedSubstring(from: selection)?.string, text.utf16.count == selection.length else {
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
                guard let text = client.attributedSubstring(from: NSRange(location: start, length: selection.location - start))?.string,
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
        replace(range, with: replacement, select: target, remember: edit, label: "result", client: client, isCurrent: isCurrent)
    }

    /// Replaces, selects the mode and confirms what the client shows.
    private func replace(_ range: NSRange, with text: String, select mode: ProbeSession.Mode, remember edit: ShortcutToggle.Edit?,
                         label: String, client: any IMKTextInput, isCurrent: @escaping () -> Bool) {
        let original = client.attributedSubstring(from: range)?.string
        client.insertText(text, replacementRange: range)
        client.selectMode(mode == .hangul ? SpikeMetadata.hangulID : SpikeMetadata.latinID)
        if let edit { toggle.remember(edit) }
        let version = generation
        let deadline = ProcessInfo.processInfo.systemUptime + Self.timeout
        let result = NSRange(location: range.location, length: text.utf16.count)
        func observe() {
            // The user typed on or moved away: what they see is theirs now.
            guard version == generation, isCurrent() else { return }
            if client.attributedSubstring(from: result)?.string == text {
                SpikeLog.notice("shortcut correction \(label)=corrected")
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                toggle.forget()
                let originalStillThere = original != nil
                    && client.attributedSubstring(from: NSRange(location: range.location, length: range.length))?.string == original
                fail(originalStillThere ? .replacementIgnored : .unexpectedResult, client)
                return
            }
            schedule(observe)
        }
        schedule(observe)
    }

    private func fail(_ reason: CorrectionFailure, _ client: any IMKTextInput) {
        SpikeLog.notice("shortcut correction skipped reason=\(reason.rawValue)")
        SpikeCorrectionFeedback.reportFailure(reason, client: client)
    }

    // MARK: terminals (ADR 0067)

    private func requestWithKeys(client: any IMKTextInput, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        let edit: ShortcutToggle.Edit
        let select: ProbeSession.Mode
        let replacement: KeyReplacement
        let isUndo: Bool
        if let last = toggle.takeRepeat() {
            edit = last
            select = last.previousMode
            replacement = KeyReplacement(erase: last.replacement.unicodeScalars.count, insert: last.original)
            isUndo = true
        } else {
            guard let plan = typed.conversion() else {
                // keys=0 after activation: the keys went to the terminal without this input method.
                SpikeLog.notice("shortcut correction no typed word cleared=\(lastClear) keys=\(keysSinceClear) byKeys=true")
                fail(.nothingToFix, client); return
            }
            edit = ShortcutToggle.Edit(location: 0, original: plan.original, replacement: plan.replacement, previousMode: mode)
            select = plan.target
            replacement = KeyReplacement(erase: plan.original.unicodeScalars.count, insert: plan.replacement)
            isUndo = false
        }
        replaceWithKeys(replacement, client: client, isCurrent: isCurrent) { [self] in
            // The terminal now shows the inserted text, typed in the selected mode.
            var word = replacement.insert
            while word.hasSuffix(" ") { word.removeLast() }
            typed.replace(with: word, mode: select)
            client.selectMode(select == .hangul ? SpikeMetadata.hangulID : SpikeMetadata.latinID)
            if !isUndo { toggle.remember(edit) }
        }
    }

    /// Erases with posted Backspaces, then inserts. Keys go only to the client's
    /// own process while it is in front, and only once the shortcut's modifiers
    /// are released (a held ⌘ would turn Backspace into ⌘Backspace).
    private func replaceWithKeys(_ replacement: KeyReplacement, client: any IMKTextInput,
                                 isCurrent: @escaping () -> Bool, posting: @escaping () -> Void) {
        let version = generation
        let clientID = ObjectIdentifier(client as AnyObject)
        let started = ProcessInfo.processInfo.systemUptime
        _ = pendingFix.start()
        func attempt() {
            // The user typed on or clicked: `key` and `interrupt` keep the word up to date.
            guard version == generation else { pendingFix.end(); return }
            guard isCurrent(), ObjectIdentifier(client as AnyObject) == clientID,
                  let front = MainActor.assumeIsolated({ NSWorkspace.shared.frontmostApplication }),
                  let clientApp = client.bundleIdentifier(), front.bundleIdentifier == clientApp else {
                SpikeLog.notice("shortcut correction result=lost-context byKeys=true")
                pendingFix.end()
                interrupt(); return
            }
            guard CGPreflightPostEventAccess() else {
                if !askedForKeyPermission {
                    askedForKeyPermission = true
                    _ = CGRequestPostEventAccess() // macOS asks the user once
                }
                pendingFix.end()
                fail(.keyPermission, client)
                return
            }
            let held = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn])
            if !held.isEmpty || hasMarkedText(client) {
                let limit = held.isEmpty ? Self.keyTimeout : Self.modifierTimeout
                guard ProcessInfo.processInfo.systemUptime < started + limit else {
                    SpikeLog.notice("shortcut correction result=expired reason=\(held.isEmpty ? "marked text" : "modifiers held") byKeys=true")
                    pendingFix.end()
                    return
                }
                schedule(attempt); return
            }
            pendingFix.end()
            posting()
            pendingInsert = (replacement.insert, client)
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
                SpikeLog.notice("shortcut correction result=keys-not-delivered arrived=\(arrived) of=\(replacement.erase)")
                // Some characters are gone already: insert the fix rather than leave a fragment.
                if arrived > 0 { self.insertAfterPostedKeys() } else { self.pendingInsert = nil; self.interrupt() }
            })
        }
        schedule(attempt)
    }

    private func insertAfterPostedKeys() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        pending.client.insertText(pending.text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        SpikeLog.notice("shortcut correction result=corrected byKeys=true")
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
