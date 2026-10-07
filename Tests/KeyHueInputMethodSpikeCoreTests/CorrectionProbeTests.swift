import Foundation
import Testing
@testable import KeyHueInputMethodSpikeCore

@MainActor
struct CorrectionProbeTests {
    private final class Client: CorrectionProbeClient {
        var identity = "session-A"
        var mode: ProbeSession.Mode? = .latin
        var selection = NSRange(location: 6, length: 0)
        var hasMarkedText = false
        var document = "dkssud"
        var ignoreReplacement = false
        var ignoreMode = false
        var modeAfterSelect: ProbeSession.Mode?
        var afterReplace: (() -> Void)?
        var afterSelect: (() -> Void)?
        var afterRead: (() -> Void)?
        var edits = 0
        var requestedRanges: [NSRange] = []
        var markedRange: NSRange {
            hasMarkedText ? NSRange(location: document.utf16.count - 1, length: 1) : NSRange(location: NSNotFound, length: 0)
        }
        var deferEffects = false
        private var queuedEffects: [() -> Void] = []
        func flushEffects() {
            let effects = queuedEffects
            queuedEffects = []
            for effect in effects { effect() }
        }
        func text(in range: NSRange) -> String? {
            requestedRanges.append(range)
            guard range.location >= 0, range.length >= 0,
                  range.location <= document.utf16.count,
                  range.length <= document.utf16.count - range.location else { return nil }
            let observed = (document as NSString).substring(with: range)
            afterRead?()
            return observed
        }
        func replace(_ range: NSRange, with text: String) {
            edits += 1
            if !ignoreReplacement {
                let effect = {
                    self.document = (self.document as NSString).replacingCharacters(in: range, with: text)
                    self.selection = NSRange(location: range.location + text.utf16.count, length: 0)
                    self.hasMarkedText = false
                }
                if deferEffects { queuedEffects.append(effect) } else { effect() }
            }
            afterReplace?()
        }
        func select(_ mode: ProbeSession.Mode) {
            if !ignoreMode {
                let effect = { self.mode = self.modeAfterSelect ?? mode }
                if deferEffects { queuedEffects.append(effect) } else { effect() }
            }
            afterSelect?()
        }
    }

    @Test func correctionUndoAndRejectedSpaceKeepTextAndModes() {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .corrected)
        #expect(client.document == "안녕 ")
        #expect(client.mode == .hangul)
        #expect(client.edits == 1) // text + boundary are one replacement
        #expect(probe.undo(client: client) == .undone)
        #expect(client.document == "dkssud")
        #expect(client.mode == .latin)
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .passThrough)
        #expect(client.edits == 2) // client handles the rejected Space once
        #expect(probe.undo(client: client) == .passThrough)
    }

    /// ADR 0064: the engine executes the policy's decision for any word; it no
    /// longer judges the fixture itself.
    @Test func anyDecidedWordIsCorrectedAndUndone() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "gksrmf"
        #expect(probe.correct(original: "gksrmf", corrected: "한글", at: 0, client: client) == .corrected)
        #expect(client.document == "한글 ")
        #expect(client.mode == .hangul)
        #expect(probe.undo(client: client) == .undone)
        #expect(client.document == "gksrmf")
        #expect(client.mode == .latin)
    }

    @Test func emptyWordsAreNeverEdited() {
        let client = Client()
        #expect(CorrectionProbe().correct(original: "", corrected: "안녕", at: 0, client: client) == .passThrough)
        #expect(CorrectionProbe().correct(original: "dkssud", corrected: "", at: 0, client: client) == .passThrough)
        #expect(client.edits == 0)
    }

    @Test func markedLatinSelectionCanTrackButArbitrarySelectionCannot() {
        let marked = NSRange(location: 5, length: 1)
        #expect(CorrectionProbe.typingCaret(selection: marked, markedRange: marked) == 6)
        #expect(CorrectionProbe.typingCaret(selection: NSRange(location: 6, length: 0), markedRange: marked) == 6)
        #expect(CorrectionProbe.typingCaret(selection: NSRange(location: 4, length: 1), markedRange: marked) == nil)
        #expect(CorrectionProbe.typingCaret(selection: NSRange(location: 0, length: 6), markedRange: marked) == nil)
        #expect(CorrectionProbe.typingCaret(selection: NSRange(location: NSNotFound, length: 0), markedRange: marked) == nil)
        // Accepting the tracked inline character never relaxes the edit guard.
        let client = Client()
        client.selection = marked
        #expect(CorrectionProbe().correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .passThrough)
        #expect(client.edits == 0)
    }

    @Test func imkInactiveRangeRequiresObservedClientCapability() {
        let unavailable = NSRange(location: NSNotFound, length: NSNotFound)
        #expect(CorrectionProbe.hasMarkedText(range: unavailable, hasReportedMarkedRange: false, sessionComposing: true))
        #expect(!CorrectionProbe.hasMarkedText(range: unavailable, hasReportedMarkedRange: true, sessionComposing: true))
        #expect(!CorrectionProbe.hasMarkedText(range: NSRange(location: NSNotFound, length: 0), hasReportedMarkedRange: false, sessionComposing: true))
        #expect(!CorrectionProbe.hasMarkedText(range: NSRange(location: 7, length: 0), hasReportedMarkedRange: true, sessionComposing: true))
        for range in [NSRange(location: 6, length: 1), NSRange(location: 6, length: NSNotFound),
                      NSRange(location: NSNotFound, length: 1)] {
            #expect(CorrectionProbe.hasMarkedText(range: range, hasReportedMarkedRange: true, sessionComposing: true))
        }
    }

    /// ADR 0081: English is never composed, so a new client that only received
    /// English text has never reported a marked range. Only this input method
    /// composes in its client: with no composition of its own, IMK's unavailable
    /// range means none. A real range is still a composition.
    @Test func unavailableRangeIsInactiveWhileTheSessionComposesNothing() {
        let unavailable = NSRange(location: NSNotFound, length: NSNotFound)
        #expect(!CorrectionProbe.hasMarkedText(range: unavailable, hasReportedMarkedRange: false, sessionComposing: false))
        #expect(!CorrectionProbe.hasMarkedText(range: unavailable, hasReportedMarkedRange: true, sessionComposing: false))
        for range in [NSRange(location: 6, length: 1), NSRange(location: 6, length: NSNotFound),
                      NSRange(location: NSNotFound, length: 1)] {
            #expect(CorrectionProbe.hasMarkedText(range: range, hasReportedMarkedRange: false, sessionComposing: false))
        }
    }

    @Test func stagedEventsConfirmRealEffectsInsteadOfCachedRanges() {
        let probe = CorrectionProbe(), client = Client()
        client.deferEffects = true
        client.hasMarkedText = true
        client.selection = NSRange(location: 5, length: 1)
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .pending)
        #expect(client.document == "dkssud") // still cached during the initial event
        #expect(client.mode == .latin)
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(client.mode == .latin) // requesting a mode is not confirmation
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .corrected)
        #expect(client.document == "안녕 ")
        #expect(probe.beginUndo(client: client) == .pending)
        #expect(client.document == "안녕 ")
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .pending)
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .undone)
        #expect(client.document == "dkssud")
        #expect(client.mode == .latin)
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .passThrough)
    }

    @Test func stagedCorrectionOfCommittedWordAndBoundaryKeepsOneSpaceAndRejection() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .corrected)
        #expect(client.document == "안녕 ")
        #expect(probe.beginUndo(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .undone)
        client.document += " "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .passThrough)
        #expect(client.document == "dkssud ")
    }

    /// A refused automatic correction says which check failed, by name only, so
    /// a real app's refusal can be diagnosed from the log (2026-10-07).
    @Test func refusedCorrectionReportsWhichCheckFailed() {
        func refusal(_ change: (Client) -> Void) -> CorrectionProbe.Refusal? {
            let probe = CorrectionProbe(), client = Client()
            client.document = "dkssud "; client.selection.location = 7
            change(client)
            let outcome = probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client)
            #expect((outcome == .passThrough) == (probe.lastRefusal != nil))
            return probe.lastRefusal
        }
        #expect(refusal { _ in } == nil)
        #expect(refusal { $0.mode = .hangul } == .notLatin)
        #expect(refusal { $0.selection.location = 3 } == .caretMoved)
        #expect(refusal { $0.selection = NSRange(location: 0, length: 7) } == .caretMoved)
        #expect(refusal { $0.document = "dkssue " } == .textChanged)
        #expect(refusal { $0.hasMarkedText = true } == .composing)
    }

    /// macOS capitalized the first word at Space (Capitalize Words Automatically)
    /// although the keys were lowercase: still corrected, and undo restores what
    /// was shown.
    @Test func systemCapitalizedFirstWordIsCorrectedAndUndoRestoresIt() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "Dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .corrected)
        #expect(client.document == "안녕 ")
        #expect(probe.beginUndo(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .undone)
        #expect(client.document == "Dkssud")
    }

    /// A capital typed with Shift (E for ㄸ) is part of the word: it is corrected as
    /// typed, and undo restores it with its capital.
    @Test func shiftedFirstLetterIsCorrectedAndUndoKeepsIt() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "Ekfrl "; client.selection.location = 6
        #expect(probe.beginCorrection(original: "Ekfrl", corrected: "딸기", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .corrected)
        #expect(client.document == "딸기 ")
        #expect(probe.beginUndo(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .undone)
        #expect(client.document == "Ekfrl")
    }

    /// The typed keys tell the system's capital from Shift: a typed E (ㄸ) is shown
    /// as typed, and only a lowercase first key shown in uppercase is accepted.
    @Test func onlyAFirstLetterTheSystemCapitalizedIsAccepted() {
        #expect(CorrectionProbe.shownWord(typed: "Ekf", shown: "Ekf") == "Ekf")
        #expect(CorrectionProbe.shownWord(typed: "ekf", shown: "Ekf") == "Ekf")
        #expect(CorrectionProbe.shownWord(typed: "ekf", shown: "EKF") == "ekf")
        #expect(CorrectionProbe.shownWord(typed: "ekf", shown: "eKf") == "ekf")
        #expect(CorrectionProbe.shownWord(typed: "Ekf", shown: "ekf") == "Ekf")
        #expect(CorrectionProbe.shownWord(typed: "ekf", shown: nil) == "ekf")
        let probe = CorrectionProbe(), client = Client()
        client.document = "DKssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .passThrough)
        #expect(probe.lastRefusal == .textChanged)
        #expect(client.edits == 0)
    }

    @Test func rejectedCommittedWordReplacementDoesNotAddAnotherBoundary() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7; client.ignoreReplacement = true
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .restoredOriginal)
        #expect(client.document == "dkssud ")
        #expect(client.edits == 1)
        #expect(client.mode == .latin)
        // ADR 0065: the app is reported to the user, without text.
        #expect(probe.lastFailure == .replacementIgnored)
    }

    @Test func aSuccessfulCorrectionReportsNoFailure() {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .corrected)
        #expect(probe.lastFailure == nil)
    }

    @Test func anUnexpectedResultIsReported() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        client.afterReplace = { client.document = "something else" }
        _ = probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client)
        #expect(probe.confirmPending(client: client) == .unsafeFailure)
        #expect(probe.lastFailure == .unexpectedResult)
    }

    @Test func stagedModeFailureConfirmsRollbackInAnotherEvent() {
        let probe = CorrectionProbe(), client = Client()
        client.deferEffects = true; client.ignoreMode = true
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .pending)
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .pending) // mode request
        #expect(probe.confirmPending(client: client) == .pending) // rollback request
        #expect(client.document == "안녕 ")
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .restoredOriginal)
        #expect(probe.lastFailure == .modeNotApplied)
        #expect(client.document == "dkssud ")
        #expect(client.mode == .latin)
        #expect(client.edits == 2)
    }

    @Test func pollingWaitsForEffectsWithoutRepeatingEditsOrModeRequests() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        client.deferEffects = true
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        let first = probe.effectSequence
        for _ in 0..<15 { #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending) }
        #expect(probe.effectSequence == first)
        #expect(client.edits == 1)
        client.flushEffects()
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        let modeRequest = probe.effectSequence
        for _ in 0..<15 { #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending) }
        #expect(probe.effectSequence == modeRequest)
        #expect(client.document == "안녕 ")
        client.flushEffects()
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .corrected)
    }

    @Test func modeCallbackIsExpectedOnlyAfterItsOwnRequest() {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.pendingModeRequest == nil)
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .pending)
        #expect(probe.pendingModeRequest == nil) // Manual Hangul here must cancel.
        client.afterSelect = { #expect(probe.pendingModeRequest == .hangul) }
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .corrected)
        #expect(probe.pendingModeRequest == nil)
        #expect(probe.beginUndo(client: client) == .pending)
        #expect(probe.pendingModeRequest == nil)
        client.afterSelect = { #expect(probe.pendingModeRequest == .latin) }
        #expect(probe.confirmPending(client: client) == .pending)
        #expect(probe.confirmPending(client: client) == .undone)
        #expect(probe.pendingModeRequest == nil)
    }

    @Test func expiredObservationRollsBackExactlyOnceAndConfirmsRecovery() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        client.ignoreMode = true
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        client.deferEffects = true
        #expect(probe.confirmPending(client: client) == .pending) // expired -> rollback
        let rollback = probe.effectSequence
        for _ in 0..<15 { #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending) }
        #expect(probe.effectSequence == rollback)
        #expect(client.edits == 2)
        client.flushEffects()
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .restoredOriginal)
        #expect(client.document == "dkssud ")
    }

    @Test func interruptedCorrectionRestoresOnlyOwnedLatinEditAndCancelsLateObservations() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.interruptPending(client: client) == .restoredOriginal)
        #expect(client.document == "dkssud ")
        client.document += "r"; client.selection.location = 8
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .passThrough)
        #expect(client.document == "dkssud r")
        #expect(client.mode == .latin)
        #expect(client.edits == 2)
    }

    @Test func interruptedModeRequestIsSupersededWithoutRepeatingTheKey() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        client.deferEffects = true
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        #expect(probe.interruptPending(client: client) == .restoredOriginal)
        client.flushEffects() // mode request, recovery edit, superseding mode request
        #expect(client.document == "dkssud ")
        #expect(client.mode == .latin)
        #expect(probe.confirmPending(client: client) == .passThrough)
    }

    @Test func reentrantInterruptionDoesNotIssueAModeRequestAfterInvalidation() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        client.ignoreMode = true
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        var modeRequests = 0
        client.afterSelect = { modeRequests += 1 }
        client.afterReplace = { probe.invalidate() }
        #expect(probe.interruptPending(client: client) == .unsafeFailure)
        #expect(modeRequests == 0)
        #expect(probe.confirmPending(client: client) == .passThrough)
    }

    @Test func reentrantKeyDuringObservationCanBeginUndoWithoutOldWorkClearingIt() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        client.afterRead = {
            client.afterRead = nil
            #expect(probe.interruptPending(client: client) == .corrected)
            #expect(probe.beginUndo(client: client) == .pending)
        }
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .unsafeFailure)
        #expect(probe.hasPendingEdit)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .undone)
        #expect(client.document == "dkssud")
        #expect(client.mode == .latin)
    }

    @Test func reentrantInputDuringPreflightPreventsTheReplacement() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        client.afterRead = {
            client.afterRead = nil
            probe.invalidate()
            client.document += "r"; client.selection.location = 8
        }
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .passThrough)
        #expect(client.document == "dkssud r")
        #expect(client.edits == 0)
    }

    @Test func interruptedAlreadyAppliedResultKeepsCorrectionAndSupportsImmediateUndo() {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .pending)
        #expect(probe.interruptPending(client: client) == .corrected)
        #expect(client.document == "안녕 ")
        #expect(probe.beginUndo(client: client) == .pending)
        #expect(probe.interruptPending(client: client) == .restoredOriginal)
        #expect(client.document == "안녕 ") // interrupted undo keeps the confirmed mode
        #expect(client.mode == .hangul)
        #expect(probe.confirmPending(client: client) == .passThrough)
    }

    @Test(arguments: [false, true])
    func pollingAndInterruptionNeverOverwriteChangedClientOrExternalEditing(_ changedClient: Bool) {
        let probe = CorrectionProbe(), client = Client()
        client.document = "dkssud "; client.selection.location = 7
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, boundaryAlreadyCommitted: true, client: client) == .pending)
        if changedClient { client.identity = "new-client" } else { client.document = "외부 편집" }
        #expect(probe.interruptPending(client: client) == .unsafeFailure)
        #expect(client.edits == 1)
        #expect(probe.confirmPending(client: client, waitForEffects: true) == .passThrough)
    }

    @Test func stagedRejectedReplacementStillDeliversConsumedSpaceOnce() {
        let probe = CorrectionProbe(), client = Client()
        client.deferEffects = true; client.ignoreReplacement = true
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .pending)
        client.ignoreReplacement = false
        #expect(probe.confirmPending(client: client) == .pending)
        client.flushEffects()
        #expect(probe.confirmPending(client: client) == .restoredOriginal)
        #expect(client.document == "dkssud ")
        #expect(client.mode == .latin)
    }

    @Test(arguments: [false, true])
    func stagedExternalEditOrDifferentClientIsNeverOverwritten(_ differentClient: Bool) {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .pending)
        if differentClient { client.identity = "session-B" } else { client.document = "외부 편집" }
        #expect(probe.confirmPending(client: client) == .unsafeFailure)
        #expect(client.edits == 1)
        #expect(client.mode == .latin)
    }

    @Test func stagedCancellationDoesNotApplyLateModeOrUndo() {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.beginCorrection(original: "dkssud", corrected: "안녕", at: 0, client: client) == .pending)
        probe.invalidate()
        #expect(probe.confirmPending(client: client) == .passThrough)
        #expect(probe.beginUndo(client: client) == .passThrough)
        #expect(client.mode == .latin)
        #expect(client.edits == 1)
    }

    @Test(arguments: ["😀 ", "e\u{301} ", "👨‍👩‍👧‍👦 "])
    func usesUTF16DocumentRangesAndReadsOnlyTheWord(_ prefix: String) {
        let probe = CorrectionProbe(), client = Client()
        client.document = prefix + "dkssud"
        client.selection.location = client.document.utf16.count
        let start = prefix.utf16.count
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: start, client: client) == .corrected)
        #expect(client.document == prefix + "안녕 ")
        #expect(probe.undo(client: client) == .undone)
        #expect(client.document == prefix + "dkssud")
        #expect(client.requestedRanges.allSatisfy { $0.location == start && $0.length <= 6 })
    }

    @Test func invalidRangesAndUnsupportedClientStateDoNotEdit() {
        for location in [-1, NSNotFound, Int.max - 1] {
            let client = Client()
            #expect(CorrectionProbe().correct(original: "dkssud", corrected: "안녕", at: location, client: client) == .passThrough)
            #expect(client.edits == 0)
        }
        for state in 0..<5 {
            let client = Client()
            switch state {
            case 0: client.selection = NSRange(location: NSNotFound, length: NSNotFound)
            case 1: client.selection.length = 1
            case 2: client.hasMarkedText = true
            case 3: client.mode = nil
            default: client.document = "edited"
            }
            #expect(CorrectionProbe().correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .passThrough)
            #expect(client.edits == 0)
        }
    }

    @Test func rejectedTextReplacementPassesSpaceWithoutSwitchingMode() {
        let probe = CorrectionProbe(), client = Client()
        client.ignoreReplacement = true
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .passThrough)
        #expect(client.document == "dkssud")
        #expect(client.mode == .latin)
        #expect(probe.undo(client: client) == .passThrough)
    }

    @Test func failedModeSwitchRestoresOriginalAndOneSpace() {
        let probe = CorrectionProbe(), client = Client()
        client.ignoreMode = true
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .restoredOriginal)
        #expect(client.document == "dkssud ")
        #expect(client.mode == .latin)
        #expect(client.edits == 2)
        #expect(probe.undo(client: client) == .passThrough)
    }

    @Test func failedUndoModeSwitchRestoresCorrectionWithoutDeletingAnotherCharacter() {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .corrected)
        client.ignoreMode = true
        #expect(probe.undo(client: client) == .restoredOriginal)
        #expect(client.document == "안녕 ")
        #expect(client.mode == .hangul)
        #expect(probe.undo(client: client) == .passThrough)
    }

    @Test(arguments: Array(0..<6))
    func staleUndoFallsBackToNormalBackspace(_ change: Int) {
        let probe = CorrectionProbe(), client = Client()
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .corrected)
        switch change {
        case 0: client.selection.location = 0
        case 1: client.selection.length = 1
        case 2: client.document = "외부 "
        case 3: client.identity = "session-B"
        case 4: client.mode = .latin
        default: probe.invalidate()
        }
        #expect(probe.undo(client: client) == .passThrough)
        #expect(client.edits == 1)
    }

    @Test func externalEditDuringModeSelectionIsNeverOverwritten() {
        let probe = CorrectionProbe(), client = Client()
        client.ignoreMode = true
        client.afterSelect = { client.document = "외부 편집" }
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .unsafeFailure)
        #expect(client.document == "외부 편집")
        #expect(client.edits == 1)
    }

    @Test func sessionInvalidationAndReentrantEventsCancelTransaction() {
        let probe = CorrectionProbe(), client = Client()
        client.afterReplace = {
            #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .passThrough)
            probe.invalidate()
        }
        #expect(probe.correct(original: "dkssud", corrected: "안녕", at: 0, client: client) == .unsafeFailure)
        #expect(client.edits == 1)
        #expect(probe.undo(client: client) == .passThrough)
    }
}
