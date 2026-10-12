import Foundation

/// What a terminal fix asks of the system (ADR 0067, 0073).
public protocol TerminalKeyPosting: AnyObject {
    /// The app in front, nil when unknown.
    func frontApp() -> (bundleID: String?, pid: pid_t)?
    /// ⌘, ⌃, ⌥, ⇧ or fn is held: a posted Backspace would carry it.
    var modifiersHeld: Bool { get }
    /// Asks for `count` Backspaces to `pid`. `completion` runs on the main thread;
    /// the keys may arrive before it.
    func requestBackspaces(_ count: Int, to pid: pid_t, completion: @escaping (TerminalKeyDelivery) -> Void)
}

/// What became of a request to post a terminal fix's Backspaces.
public enum TerminalKeyDelivery: Equatable, Sendable {
    /// Posted, or possibly still posted; the delivery check sees whether they arrive (ADR 0083).
    case posted
    /// Neither KeyHue nor this input method may post keys.
    case noPermission
    /// KeyHue refused (another app in front, secure input, ...); nothing was typed.
    case refused
}

/// Terminals (ADR 0067): the typed word is erased with posted Backspaces, which
/// come back through the input method and pass to the client untouched; the fix
/// is inserted after the last one.
extension ShortcutCorrector {
    /// One of the posted Backspaces came back through the input method. The
    /// caller passes it to the client untouched. After the last one, the fix is
    /// inserted once the client has handled it.
    public func postedKeyArrived(isBackspace: Bool, markerSeen: @autoclosure () -> Bool) -> Bool {
        guard posted.isPending else { return false }
        let arrival = posted.arrived(isBackspace: isBackspace)
        guard arrival != .notOurs else { return false }
        if arrival == .passThroughLast {
            report(.keysDelivered(markerSeen: markerSeen()))
            scheduler.schedule(after: 0) { [weak self] in self?.insertAfterPostedKeys() }
        }
        return true
    }

    func requestWithKeys(client: any ShortcutCorrectionClient, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        let edit: ShortcutToggle.Edit
        let select: ProbeSession.Mode
        let replacement: KeyReplacement
        let isUndo: Bool
        if let last = toggle.takeRepeat() {
            edit = last
            select = last.previousMode
            replacement = KeyReplacement(undoing: last)
            isUndo = true
        } else {
            guard let plan = typed.conversion() else {
                // keys=0 after activation: the keys went to the terminal without this input method.
                report(.noTypedWord(cleared: lastClear, keys: keysSinceClear))
                fail(lastClear == "selection" ? .terminalSelection : .nothingToFix, client); return
            }
            edit = ShortcutToggle.Edit(location: 0, original: plan.original, replacement: plan.replacement, previousMode: mode)
            select = plan.target
            replacement = KeyReplacement(correcting: edit)
            isUndo = false
        }
        replaceWithKeys(replacement, client: client, isCurrent: isCurrent, revert: {
            // Nothing was erased: back to the mode the user was typing in.
            client.select(mode)
        }) { [weak self] in
            guard let self else { return }
            // The terminal now shows the inserted text, typed in the selected mode.
            var word = replacement.insert
            while word.hasSuffix(" ") { word.removeLast() }
            typed.replace(with: word, mode: select)
            client.select(select)
            if !isUndo { toggle.remember(edit) }
        }
    }

    /// Erases with posted Backspaces, then inserts. Keys go only to the client's
    /// own process while it is in front, and only once the shortcut's modifiers
    /// are released (a held ⌘ would turn Backspace into ⌘Backspace).
    private func replaceWithKeys(_ replacement: KeyReplacement, client: any ShortcutCorrectionClient,
                                 isCurrent: @escaping () -> Bool, revert: @escaping () -> Void,
                                 posting: @escaping () -> Void) {
        let version = generation
        let started = scheduler.now
        _ = pendingFix.start()
        func attempt() {
            // The user typed on or clicked: `key` and `interrupt` keep the word up to date.
            guard version == generation else { pendingFix.end(); return }
            guard isCurrent(), let front = keys.frontApp(),
                  FrontClient.matches(clientID: client.bundleID, frontID: front.bundleID) else {
                report(.lostContext(byKeys: true))
                pendingFix.end()
                interrupt(); return
            }
            let held = keys.modifiersHeld
            if held || client.hasMarkedText {
                let limit = held ? Self.modifierTimeout : Self.keyTimeout
                guard scheduler.now < started + limit else {
                    report(.expired(modifiersHeld: held))
                    pendingFix.end()
                    return
                }
                scheduler.schedule(after: Self.interval, attempt); return
            }
            pendingFix.end()
            // The mode is selected before the keys are posted, as before ADR 0073: a
            // mode change while the terminal handles the Backspaces lost one of them.
            posting()
            // Expect the keys before asking for them: they come back through this
            // input method once this main-thread turn is over.
            pendingInsert = (replacement.insert, client)
            posted.post(replacement.erase)
            if replacement.erase == 0 { insertAfterPostedKeys(); return }
            keys.requestBackspaces(replacement.erase, to: front.pid) { [weak self] delivery in
                self?.backspacesRequested(delivery, erase: replacement.erase, client: client, revert: revert)
            }
        }
        scheduler.schedule(after: Self.interval, attempt)
    }

    private func backspacesRequested(_ delivery: TerminalKeyDelivery, erase: Int,
                                     client: any ShortcutCorrectionClient, revert: @escaping () -> Void) {
        switch delivery {
        case .posted:
            scheduler.schedule(after: Self.deliveryTimeout) { [weak self] in
                guard let self, posted.isPending else { return }
                let arrived = posted.abandon()
                report(.keysNotDelivered(arrived: arrived, of: erase))
                // Some characters are gone already: insert the fix rather than leave a fragment.
                if arrived > 0 { insertAfterPostedKeys(); return }
                // Nothing was erased: the word stays as typed, in the mode it was typed in.
                pendingInsert = nil
                revert()
                interrupt()
                fail(.replacementIgnored, client)
            }
        case .noPermission, .refused:
            _ = posted.abandon()
            pendingInsert = nil
            revert()
            // refused: notFront, secureInput, untrusted, invalid. Nothing was typed.
            if delivery == .noPermission { fail(.keyPermission, client) }
            interrupt(reason: "context")
        }
    }

    private func insertAfterPostedKeys() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        pending.client.insert(pending.text)
        report(.correctedByKeys)
    }
}
