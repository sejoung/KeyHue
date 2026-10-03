import AppKit
import Carbon
import InputMethodKit
import KeyHueInputMethodSpikeCore

/// An explicitly named acceptance client is the entire allowlist. Normal apps
/// never enter this path, even when typing the fixture. This is not a setting.
final class IMKCorrectionProbe {
    static let clientBundleID = "io.github.sejoung.keyhue.testclient.correction-probe"
    private let engine = CorrectionProbe()
    private var keys = ""
    private var start: Int?
    private var applying = false
    private var waitingForSpace: (original: String, location: Int, identity: String)?
    // Keep the reporting client alive: a later object cannot reuse its address.
    private var markedRangeReportingClient: (any IMKTextInput)?
    private var observation: DispatchWorkItem?
    private var observationGeneration = 0
    private var deadline = 0.0
    private var recovering = false
    private let observationInterval = 0.01
    private let observationTimeout = 0.15

    private var hasPendingWork: Bool { waitingForSpace != nil || engine.hasPendingEdit }

    private func stopObservation() {
        observationGeneration &+= 1
        observation?.cancel()
        observation = nil
    }

    /// An ended input context supersedes even a currently reentrant RPC.
    func invalidateContext() {
        stopObservation()
        engine.invalidate()
        waitingForSpace = nil
        keys = ""; start = nil
    }

    private func adapter(client: any IMKTextInput, identity: String,
                         currentMode: @escaping () -> ProbeSession.Mode?) -> Client {
        let range = client.markedRange()
        if range.location != NSNotFound, range.length > 0, range.length != NSNotFound {
            markedRangeReportingClient = client
        }
        return Client(client: client, session: identity, currentMode: currentMode,
                      hasReportedMarkedRange: markedRangeReportingClient as AnyObject? === client as AnyObject)
    }

    func invalidate(reason: String = "event") {
        guard !applying else { return }
        // Mode selection may invoke these callbacks between the two observations.
        // The next observation verifies the exact client, text, caret and mode.
        if engine.hasPendingEdit || waitingForSpace != nil,
           ["activation", "deactivation", "commit callback", "cancel callback", "mode callback"].contains(reason) { return }
        if start != nil { SpikeLog.notice("correction probe word invalidated reason=\(reason)") }
        engine.invalidate()
        stopObservation()
        keys = ""
        start = nil
        waitingForSpace = nil
    }

    func letter(_ key: Character, client: any IMKTextInput, mode: ProbeSession.Mode) {
        stopObservation()
        waitingForSpace = nil
        engine.invalidate()
        guard client.bundleIdentifier() == Self.clientBundleID, mode == .latin,
              key.isASCII, key.isLetter else { keys = ""; start = nil; return }
        let selection = client.selectedRange()
        guard let caret = CorrectionProbe.typingCaret(selection: selection, markedRange: client.markedRange()) else {
            SpikeLog.notice("correction probe tracking rejected: selectionKnown=\(selection.location != NSNotFound) empty=\(selection.length == 0)")
            invalidate(); return
        }
        if keys.isEmpty {
            // Never treat a suffix of an identifier or edited word as a new word.
            if caret > 0 {
                let before = client.attributedSubstring(from: NSRange(location: caret - 1, length: 1))?.string
                guard before == " " || before == "\n" || before == "\t" else {
                    SpikeLog.notice("correction probe tracking rejected: not a word boundary")
                    invalidate(); return
                }
            }
            start = caret
        }
        guard let start, caret == start + keys.utf16.count, keys.count < 64 else {
            SpikeLog.notice("correction probe tracking rejected: caret moved or word too long")
            invalidate(); return
        }
        keys.append(key)
        SpikeLog.notice("correction probe tracked count=\(keys.count)")
    }

    func space(client: any IMKTextInput, identity: String, currentMode: @escaping () -> ProbeSession.Mode?) -> Bool {
        stopObservation()
        guard client.bundleIdentifier() == Self.clientBundleID, let start else {
            SpikeLog.notice("correction probe skipped: no tracked word session=\(identity)")
            invalidate(); return false
        }
        defer { keys = ""; self.start = nil }
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        SpikeLog.notice("correction probe boundary session=\(identity) count=\(keys.count) fixture=\(keys == "dkssud") mode=\(adapter.mode?.rawValue ?? "unavailable")")
        if keys == "dkssud", adapter.mode == .latin {
            waitingForSpace = (keys, start, adapter.identity)
        }
        // Let normal input commit Space once. The next main-loop observation
        // verifies the unmarked word + boundary, without any synthetic key.
        return false
    }

    func backspace(client: any IMKTextInput, identity: String, currentMode: @escaping () -> ProbeSession.Mode?) -> Bool {
        stopObservation()
        guard client.bundleIdentifier() == Self.clientBundleID else { return false }
        applying = true
        defer { applying = false }
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        let result = engine.beginUndo(client: adapter)
        if !result.handled {
            keys = ""; start = nil; waitingForSpace = nil
            engine.invalidate()
        }
        if result == .unsafeFailure { SpikeLog.error("correction probe undo failed verification session=\(identity)") }
        return result.handled
    }

    /// Called before an actual key/click is processed. No input is consumed or
    /// replayed while waiting. Cancel unstarted work and restore only owned edits.
    func interrupt(client: any IMKTextInput, identity: String, currentMode: @escaping () -> ProbeSession.Mode?) {
        guard hasPendingWork else { return }
        stopObservation()
        applying = true
        defer { applying = false }
        let location = engine.pendingOriginalLocation
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        if waitingForSpace != nil {
            waitingForSpace = nil
            engine.invalidate()
            keys = ""; start = nil
            SpikeLog.notice("correction probe interrupted before replacement session=\(identity)")
        } else {
            let result = engine.interruptPending(client: adapter)
            record(result, location: location, identity: identity)
        }
    }

    func schedule(client: any IMKTextInput, identity: String,
                  currentMode: @escaping () -> ProbeSession.Mode?, isCurrent: @escaping () -> Bool) {
        guard hasPendingWork, observation == nil else { return }
        deadline = ProcessInfo.processInfo.systemUptime + observationTimeout
        recovering = false
        enqueue(client: client, identity: identity, currentMode: currentMode, isCurrent: isCurrent)
    }

    private func enqueue(client: any IMKTextInput, identity: String,
                         currentMode: @escaping () -> ProbeSession.Mode?, isCurrent: @escaping () -> Bool) {
        let generation = observationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, Thread.isMainThread, self.observationGeneration == generation else { return }
            self.observation = nil
            guard isCurrent() else {
                self.invalidate(reason: "observation lost context")
                return
            }
            self.observe(client: client, identity: identity, currentMode: currentMode)
            if self.hasPendingWork, self.observationGeneration == generation {
                self.enqueue(client: client, identity: identity, currentMode: currentMode, isCurrent: isCurrent)
            }
        }
        observation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + observationInterval, execute: work)
    }

    private func observe(client: any IMKTextInput, identity: String,
                         currentMode: @escaping () -> ProbeSession.Mode?) {
        let generation = observationGeneration
        applying = true
        defer { applying = false }
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        guard observationGeneration == generation else { return }
        if let candidate = waitingForSpace {
            waitingForSpace = nil
            guard adapter.identity == candidate.identity else {
                engine.invalidate(); stopObservation()
                SpikeLog.notice("correction probe rejected: client changed session=\(identity)")
                return
            }
            let result = engine.beginCorrection(original: candidate.original, at: candidate.location,
                                                boundaryAlreadyCommitted: true, client: adapter)
            guard observationGeneration == generation else { return }
            SpikeLog.notice("correction probe automatic request session=\(identity) outcome=\(result)")
            if !engine.hasPendingEdit { stopObservation(); return }
        }
        let expired = ProcessInfo.processInfo.systemUptime >= deadline
        if expired, recovering {
            let location = engine.pendingOriginalLocation
            let result = engine.interruptPending(client: adapter)
            guard observationGeneration == generation else { return }
            record(result, location: location, identity: identity)
            stopObservation()
            SpikeLog.error("correction probe recovery deadline session=\(identity)")
            return
        }
        // Synchronous replies outside a key callback may advance several phases.
        // Never spin waiting for one reply; retry unchanged state on a later turn.
        for _ in 0..<(expired ? 1 : 4) {
            let location = engine.pendingOriginalLocation
            let sequence = engine.effectSequence
            let result = engine.confirmPending(client: adapter, waitForEffects: !expired)
            guard observationGeneration == generation else { return }
            if !engine.hasPendingEdit {
                record(result, location: location, identity: identity)
                stopObservation()
                return
            }
            if engine.effectSequence == sequence { break }
        }
        if expired {
            recovering = true
            deadline = ProcessInfo.processInfo.systemUptime + observationTimeout
            SpikeLog.notice("correction probe deadline: verifying recovery session=\(identity)")
        }
    }

    private func record(_ result: CorrectionProbe.Outcome, location: Int?, identity: String) {
        if result == .undone { keys = "dkssud"; start = location }
        if result == .restoredOriginal || result == .unsafeFailure { keys = ""; start = nil }
        SpikeLog.notice("correction probe automatic result session=\(identity) outcome=\(result)")
    }

    private final class Client: CorrectionProbeClient {
        let client: any IMKTextInput
        let session: String
        let currentMode: () -> ProbeSession.Mode?
        let hasReportedMarkedRange: Bool
        init(client: any IMKTextInput, session: String, currentMode: @escaping () -> ProbeSession.Mode?,
             hasReportedMarkedRange: Bool) {
            self.client = client; self.session = session; self.currentMode = currentMode
            self.hasReportedMarkedRange = hasReportedMarkedRange
        }
        // uniqueClientIdentifierString wraps globallyUniqueString and returns a
        // new token on each call. The controller owns one input session; combine
        // its UUID with the retained IMK client object's identity instead.
        var identity: String { session + ":" + String(describing: ObjectIdentifier(client as AnyObject)) }
        var mode: ProbeSession.Mode? { currentMode() }
        var selection: NSRange { client.selectedRange() }
        var hasMarkedText: Bool {
            CorrectionProbe.hasMarkedText(range: client.markedRange(), hasReportedMarkedRange: hasReportedMarkedRange)
        }
        var markedRange: NSRange { client.markedRange() }
        func text(in range: NSRange) -> String? { client.attributedSubstring(from: range)?.string }
        func replace(_ range: NSRange, with text: String) { client.insertText(text, replacementRange: range) }
        func select(_ mode: ProbeSession.Mode) {
            client.selectMode(mode == .hangul ? SpikeMetadata.hangulID : SpikeMetadata.latinID)
        }
    }
}
