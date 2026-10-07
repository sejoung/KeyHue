import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// Automatic correction (ADR 0064): `CorrectionPolicy` decides with the detector,
/// `CorrectionProbe` executes and verifies the staged edits, for clients that
/// `CorrectionRouting` routes to automatic mode (test client, verified apps).
final class IMKCorrectionProbe {
    private let engine = CorrectionProbe()
    private var policy = CorrectionPolicy(judge: SpikeCorrectionJudge.shared)
    private var applying = false
    private var waitingForSpace: (original: String, corrected: String, location: Int, identity: String)?
    // Keep the reporting client alive: a later object cannot reuse its address.
    private var markedRangeReportingClient: (any IMKTextInput)?
    private var observation: DispatchWorkItem?
    private var observationGeneration = 0
    private var deadline = 0.0
    private var recovering = false
    private let observationInterval = 0.01
    private let observationTimeout = 0.15
    /// Whether the session has a composition of its own (ADR 0081).
    private let sessionComposing: () -> Bool

    init(sessionComposing: @escaping () -> Bool) {
        self.sessionComposing = sessionComposing
    }

    private var hasPendingWork: Bool { waitingForSpace != nil || engine.hasPendingEdit }

    private func stopObservation() {
        observationGeneration &+= 1
        observation?.cancel()
        observation = nil
    }

    /// This adapter serves the automatic route; secure input is checked on every decision.
    private func environment(_ client: any IMKTextInput) -> CorrectionEnvironment {
        var environment = CorrectionEnvironment(mode: .automatic)
        environment.secureInput = IsSecureEventInputEnabled()
        environment.appExcluded = SpikeCorrectionSettings.shared.excludedApps.contains(client.bundleIdentifier() ?? "")
        environment.ignoredWords = SpikeCorrectionSettings.shared.ignoredWords
        return environment
    }

    private func log(_ decision: CorrectionDecision, source: String) {
        if case .skipped(let reason) = decision { SpikeLog.notice("automatic correction skipped source=\(source) reason=\(reason.logName)") }
    }

    func activated() {
        SpikeCorrectionSettings.shared.start()
        SpikeCorrectionJudge.shared.load()
    }

    /// An ended input context supersedes even a currently reentrant RPC.
    func invalidateContext() {
        stopObservation()
        engine.invalidate()
        waitingForSpace = nil
        policy.interrupt(.contextChanged)
    }

    func modeRequested(_ mode: ProbeSession.Mode, client: any IMKTextInput) {
        // Do not infer origin from a stale TIS snapshot. Preserve only the
        // callback expected from our currently outstanding mode request.
        guard engine.pendingModeRequest != mode else { return }
        log(policy.modeSignal(to: mode, environment: environment(client)), source: "mode callback")
        invalidateContext()
    }

    private func adapter(client: any IMKTextInput, identity: String,
                         currentMode: @escaping () -> ProbeSession.Mode?) -> Client {
        let range = client.markedRange()
        if range.location != NSNotFound, range.length > 0, range.length != NSNotFound {
            markedRangeReportingClient = client
        }
        return Client(client: client, session: identity, currentMode: currentMode,
                      hasReportedMarkedRange: markedRangeReportingClient as AnyObject? === client as AnyObject,
                      sessionComposing: sessionComposing)
    }

    func invalidate(reason: String = "event") {
        guard !applying else { return }
        // Mode selection may invoke these callbacks between the two observations.
        // The next observation verifies the exact client, text, caret and mode.
        if engine.hasPendingEdit || waitingForSpace != nil,
           ["activation", "deactivation", "commit callback", "cancel callback", "mode callback"].contains(reason) { return }
        engine.invalidate()
        stopObservation()
        waitingForSpace = nil
        switch reason {
        case "mouse": policy.interrupt(.mouse)
        case "activation", "deactivation", "commit callback", "cancel callback": policy.interrupt(.contextChanged)
        case "client reconciliation": policy.interrupt(.externalEdit)
        default: policy.interrupt(.otherKey)
        }
    }

    func letter(_ key: Character, client: any IMKTextInput, mode: ProbeSession.Mode) {
        stopObservation()
        waitingForSpace = nil
        engine.invalidate()
        guard let caret = CorrectionProbe.typingCaret(selection: client.selectedRange(), markedRange: client.markedRange()) else {
            policy.interrupt(.cursorMoved); return
        }
        // Never treat a suffix of an identifier or edited word as a new word.
        _ = policy.letter(key, caret: caret, atWordStart: Self.isWordStart(caret, client), mode: mode, environment: environment(client))
    }

    func space(client: any IMKTextInput, identity: String, mode: ProbeSession.Mode,
               currentMode: @escaping () -> ProbeSession.Mode?) -> Bool {
        stopObservation()
        guard let caret = CorrectionProbe.typingCaret(selection: client.selectedRange(), markedRange: client.markedRange()) else {
            invalidate(); return false
        }
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        let decision = policy.space(caret: caret, mode: mode, environment: environment(client))
        log(decision, source: "space")
        if case .correct(let edit, _) = decision, adapter.mode == .latin {
            SpikeLog.notice("automatic correction decided session=\(identity) originalLength=\(edit.original.utf16.count)")
            waitingForSpace = (String(edit.original.dropLast()), String(edit.replacement.dropLast()), edit.location, adapter.identity)
        }
        // Let normal input commit Space once. The next main-loop observation
        // verifies the unmarked word + boundary, without any synthetic key.
        return false
    }

    func backspace(client: any IMKTextInput, identity: String, currentMode: @escaping () -> ProbeSession.Mode?) -> Bool {
        stopObservation()
        applying = true
        defer { applying = false }
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        let result = engine.beginUndo(client: adapter)
        // The policy mirrors the undo: the restored word's next Space is not corrected again.
        if case .undo(let edit, _) = policy.backspace(), result.handled {
            SpikeCorrectionFeedback.recordUndone(original: edit.original,
                                                 corrected: edit.replacement.trimmingCharacters(in: .whitespaces),
                                                 mode: .automatic, client: client)
        }
        if !result.handled {
            waitingForSpace = nil
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
        let adapter = adapter(client: client, identity: identity, currentMode: currentMode)
        if waitingForSpace != nil {
            waitingForSpace = nil
            engine.invalidate()
            // The decided correction never happened: it has nothing to undo.
            policy.interrupt(.otherKey)
            SpikeLog.notice("correction probe interrupted before replacement session=\(identity)")
        } else {
            let result = engine.interruptPending(client: adapter)
            record(result, identity: identity)
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
            let result = engine.beginCorrection(original: candidate.original, corrected: candidate.corrected,
                                                at: candidate.location, boundaryAlreadyCommitted: true, client: adapter)
            guard observationGeneration == generation else { return }
            let refusal = engine.lastRefusal.map { " reason=\($0.rawValue)" } ?? ""
            SpikeLog.notice("correction probe automatic request session=\(identity) outcome=\(result)\(refusal)")
            if !engine.hasPendingEdit { stopObservation(); return }
        }
        let expired = ProcessInfo.processInfo.systemUptime >= deadline
        if expired, recovering {
            let result = engine.interruptPending(client: adapter)
            guard observationGeneration == generation else { return }
            // No confirmation before the deadline: the app did not apply our edit.
            let fallback: CorrectionFailure = result == .restoredOriginal ? .replacementIgnored : .unexpectedResult
            record(result, identity: identity, failedIn: client, fallback: fallback)
            stopObservation()
            SpikeLog.error("correction probe recovery deadline session=\(identity)")
            return
        }
        // Synchronous replies outside a key callback may advance several phases.
        // Never spin waiting for one reply; retry unchanged state on a later turn.
        for _ in 0..<(expired ? 1 : 4) {
            let sequence = engine.effectSequence
            let result = engine.confirmPending(client: adapter, waitForEffects: !expired)
            guard observationGeneration == generation else { return }
            if !engine.hasPendingEdit {
                record(result, identity: identity, failedIn: client)
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

    /// `failedIn`: the client of an observation (not a cancellation by the user's
    /// next key), whose failure is reported to the user (ADR 0065).
    private func record(_ result: CorrectionProbe.Outcome, identity: String,
                        failedIn client: (any IMKTextInput)? = nil, fallback: CorrectionFailure? = nil) {
        if result == .restoredOriginal || result == .unsafeFailure {
            policy.interrupt(.externalEdit)
            if let client, let failure = engine.lastFailure ?? fallback {
                SpikeCorrectionFeedback.reportFailure(failure, client: client)
            }
        }
        SpikeLog.notice("correction probe automatic result session=\(identity) outcome=\(result)")
    }

    /// Document start or after whitespace. One client query; the policy asks only when needed.
    private static func isWordStart(_ caret: Int, _ client: any IMKTextInput) -> Bool {
        guard caret > 0 else { return true }
        let before = client.attributedSubstring(from: NSRange(location: caret - 1, length: 1))?.string
        return before == " " || before == "\n" || before == "\t"
    }

    private final class Client: CorrectionProbeClient {
        let client: any IMKTextInput
        let session: String
        let currentMode: () -> ProbeSession.Mode?
        let hasReportedMarkedRange: Bool
        let sessionComposing: () -> Bool
        init(client: any IMKTextInput, session: String, currentMode: @escaping () -> ProbeSession.Mode?,
             hasReportedMarkedRange: Bool, sessionComposing: @escaping () -> Bool) {
            self.client = client; self.session = session; self.currentMode = currentMode
            self.hasReportedMarkedRange = hasReportedMarkedRange
            self.sessionComposing = sessionComposing
        }
        // uniqueClientIdentifierString wraps globallyUniqueString and returns a
        // new token on each call. The controller owns one input session; combine
        // its UUID with the retained IMK client object's identity instead.
        var identity: String { session + ":" + String(describing: ObjectIdentifier(client as AnyObject)) }
        var mode: ProbeSession.Mode? { currentMode() }
        var selection: NSRange { client.selectedRange() }
        var hasMarkedText: Bool {
            CorrectionProbe.hasMarkedText(range: client.markedRange(), hasReportedMarkedRange: hasReportedMarkedRange,
                                          sessionComposing: sessionComposing())
        }
        var markedRange: NSRange { client.markedRange() }
        func text(in range: NSRange) -> String? { client.attributedSubstring(from: range)?.string }
        func replace(_ range: NSRange, with text: String) { client.insertText(text, replacementRange: range) }
        func select(_ mode: ProbeSession.Mode) {
            client.selectMode(mode == .hangul ? SpikeMetadata.hangulID : SpikeMetadata.latinID)
        }
    }
}
