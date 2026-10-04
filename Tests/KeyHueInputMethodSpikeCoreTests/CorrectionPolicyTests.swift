import Testing
@testable import KeyHueInputMethodSpikeCore

/// Stands in for the language detector (step 3): exact words only.
private final class FakeJudge: CorrectionJudging {
    var isReady = true
    var corrections = ["dkssud": "안녕", "rk": "가"]
    var asked: [(String, CorrectionMode)] = []
    func hangul(for word: String, mode: CorrectionMode) -> String? {
        asked.append((word, mode))
        return corrections[word]
    }
}

/// ADR 0064: off / manual (correct on the user's switch right after the word) /
/// automatic (correct at Space). Positions are UTF-16 offsets in the document.
private struct Harness {
    let judge = FakeJudge()
    var policy: CorrectionPolicy
    var environment: CorrectionEnvironment

    init(_ mode: CorrectionMode) {
        policy = CorrectionPolicy(judge: judge)
        environment = CorrectionEnvironment(mode: mode)
    }

    /// Types Latin letters from `start` (a word start) and returns the next caret.
    @discardableResult
    mutating func type(_ word: String, at start: Int = 0, mode: ProbeSession.Mode = .latin) -> Int {
        var caret = start
        for key in word {
            _ = policy.letter(key, caret: caret, atWordStart: caret == start, mode: mode, environment: environment)
            caret += 1
        }
        return caret
    }

    mutating func space(at caret: Int) -> CorrectionDecision {
        policy.space(caret: caret, mode: .latin, environment: environment)
    }

    mutating func signal(_ mode: ProbeSession.Mode?) -> CorrectionDecision {
        policy.modeSignal(to: mode, environment: environment)
    }
}

@Suite("Correction policy (ADR 0064)")
struct CorrectionPolicyTests {
    // MARK: manual

    @Test func manualCorrectsAFinishedWordWhenTheUserSwitchesToHangul() {
        var h = Harness(.manual)
        let end = h.type("dkssud", at: 3)
        #expect(h.space(at: end) == .none) // Space alone never corrects in manual mode
        let edit = CorrectionEdit(location: 3, original: "dkssud ", replacement: "안녕 ")
        #expect(h.signal(.hangul) == .correct(edit, selectHangul: false))
        #expect(h.judge.asked.map(\.1) == [.manual])
    }

    @Test func manualCorrectsAWordStillBeingTyped() {
        var h = Harness(.manual)
        #expect(!h.policy.isTrackingWord)
        h.type("dkssud")
        // The adapter asks the client for the character before the caret only at a word start.
        #expect(h.policy.isTrackingWord)
        #expect(h.signal(.hangul) == .correct(CorrectionEdit(location: 0, original: "dkssud", replacement: "안녕"), selectHangul: false))
    }

    @Test func manualLeavesRealEnglishAlone() {
        var h = Harness(.manual)
        let end = h.type("hello")
        _ = h.space(at: end)
        #expect(h.signal(.hangul) == .skipped(.notMistyped))
        // The word is finished: switching again later does not reconsider it.
        #expect(h.signal(.hangul) == .none)
        #expect(h.judge.asked.count == 1)
    }

    /// The switch must come right after the word.
    @Test(arguments: [CorrectionInterruption.otherKey, .mouse, .cursorMoved, .contextChanged, .externalEdit])
    func anythingBetweenTheWordAndTheSwitchCancels(_ interruption: CorrectionInterruption) {
        var h = Harness(.manual)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        h.policy.interrupt(interruption)
        #expect(h.signal(.hangul) == .skipped(.dropped(.interrupted(interruption))))
    }

    @Test func onlyTheLastWordIsConsidered() {
        var h = Harness(.manual)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        h.type("rk", at: end + 1)
        #expect(h.signal(.hangul) == .correct(CorrectionEdit(location: 7, original: "rk", replacement: "가"), selectHangul: false))
    }

    /// Return and Tab may submit or move focus; the word is no longer a candidate.
    @Test(arguments: [CorrectionInterruption.returnKey, .tab])
    func returnOrTabEndsTheCandidate(_ interruption: CorrectionInterruption) {
        var h = Harness(.manual)
        h.type("dkssud")
        h.policy.interrupt(interruption)
        #expect(h.signal(.hangul) == .skipped(.dropped(.interrupted(interruption))))
    }

    @Test func aSecondSpaceEndsTheCandidate() {
        var h = Harness(.manual)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        #expect(h.space(at: end + 1) == .none)
        #expect(h.signal(.hangul) == .skipped(.dropped(.extraSpace)))
    }

    @Test(arguments: [ProbeSession.Mode.latin, nil])
    func switchingAnywhereButHangulDropsTheCandidate(_ target: ProbeSession.Mode?) {
        var h = Harness(.manual)
        h.type("dkssud")
        #expect(h.signal(target) == .none)
        #expect(h.signal(.hangul) == .skipped(.dropped(.switchedAway)))
    }

    /// Both the mode callback and the selection notification announce one switch,
    /// in either order (ADR 0064 experiment). The duplicate keeps the undo.
    @Test func duplicateSignalOfTheSameSwitchKeepsTheUndo() {
        var h = Harness(.manual)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        let edit = CorrectionEdit(location: 0, original: "dkssud ", replacement: "안녕 ")
        #expect(h.signal(.hangul) == .correct(edit, selectHangul: false))
        #expect(h.signal(.hangul) == .skipped(.duplicateSignal))
        #expect(h.policy.backspace() == .undo(edit, selectLatin: false))
    }

    /// The user chose Hangul; undo restores only the text.
    @Test func manualUndoRestoresTextAndKeepsTheMode() {
        var h = Harness(.manual)
        h.type("dkssud")
        let edit = CorrectionEdit(location: 0, original: "dkssud", replacement: "안녕")
        #expect(h.signal(.hangul) == .correct(edit, selectHangul: false))
        #expect(h.policy.backspace() == .undo(edit, selectLatin: false))
        #expect(h.policy.backspace() == .none) // only once
    }

    /// The adapter checks the client for a word start only when no word is being
    /// typed. A word finished with Space is no longer being typed: the next letter
    /// must be checked, or every second word of a sentence would be dropped.
    @Test func aFinishedWordIsNotBeingTyped() {
        var h = Harness(.manual)
        let end = h.type("hello")
        #expect(h.policy.isTrackingWord)
        _ = h.space(at: end)
        #expect(!h.policy.isTrackingWord)
        h.type("dkssud", at: end + 1)
        #expect(h.signal(.hangul) == .correct(CorrectionEdit(location: 6, original: "dkssud", replacement: "안녕"), selectHangul: false))
    }

    /// Log names carry no module prefixes and no text.
    @Test func skipReasonsHaveShortLogNames() {
        #expect(CorrectionSkip.notMistyped.logName == "notMistyped")
        #expect(CorrectionSkip.dropped(.notAtWordStart).logName == "dropped.notAtWordStart")
        #expect(CorrectionSkip.dropped(.interrupted(.cursorMoved)).logName == "dropped.interrupted.cursorMoved")
    }

    /// Edited words are excluded: Backspace inside a word drops it.
    @Test func backspaceInsideAWordDropsIt() {
        var h = Harness(.manual)
        h.type("dkssudd")
        #expect(h.policy.backspace() == .none)
        #expect(h.signal(.hangul) == .skipped(.dropped(.edited)))
    }

    /// Ordinary switching with nothing typed is not a skipped correction (no log noise).
    @Test func aPlainSwitchIsNotReported() {
        var h = Harness(.manual)
        #expect(h.signal(.hangul) == .none)
        #expect(h.signal(.latin) == .none)
    }

    /// Hangul typing is not a Latin word that failed; it is not reported either.
    @Test func lettersTypedInHangulModeAreNotCandidates() {
        var h = Harness(.manual)
        h.type("dkssud", mode: .hangul)
        #expect(h.signal(.hangul) == .none)
        #expect(h.judge.asked.isEmpty)
    }

    // MARK: automatic

    @Test func automaticCorrectsAtSpaceAndSelectsHangul() {
        var h = Harness(.automatic)
        let end = h.type("dkssud", at: 2)
        #expect(h.space(at: end) == .correct(CorrectionEdit(location: 2, original: "dkssud ", replacement: "안녕 "), selectHangul: true))
        #expect(h.judge.asked.map(\.1) == [.automatic])
    }

    @Test func automaticDoesNotWaitForASwitch() {
        var h = Harness(.automatic)
        h.type("dkssud")
        #expect(h.signal(.hangul) == .skipped(.externalSwitch))
        #expect(h.signal(.hangul) == .none)
    }

    /// Undo puts back the word without the Space and the Latin mode; the same
    /// word is not corrected again at the next Space (INPUT_METHOD_DESIGN §5).
    @Test func automaticUndoRestoresLatinAndIsNotRepeated() {
        var h = Harness(.automatic)
        let end = h.type("dkssud")
        guard case .correct = h.space(at: end) else { Issue.record("expected a correction"); return }
        let undo = CorrectionEdit(location: 0, original: "dkssud", replacement: "안녕 ")
        #expect(h.policy.backspace() == .undo(undo, selectLatin: true))
        #expect(h.space(at: end) == .skipped(.alreadyUndone))
    }

    /// ADR 0058: an external mode selection cancels automatic work and its undo.
    @Test func externalSwitchCancelsAutomaticUndo() {
        var h = Harness(.automatic)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        #expect(h.signal(.hangul) == .skipped(.externalSwitch))
        #expect(h.policy.backspace() == .none)
    }

    @Test func automaticLeavesRealEnglishAlone() {
        var h = Harness(.automatic)
        let end = h.type("hello")
        #expect(h.space(at: end) == .skipped(.notMistyped))
        // The decision is made once; a second Space is just a Space.
        #expect(h.space(at: end + 1) == .none)
    }

    // MARK: both modes

    @Test(arguments: [CorrectionMode.manual, .automatic])
    func undoIsOnlyImmediate(_ mode: CorrectionMode) {
        var h = Harness(mode)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        _ = h.signal(.hangul)
        h.policy.interrupt(.cursorMoved)
        #expect(h.policy.backspace() == .none)
    }

    @Test(arguments: [CorrectionMode.manual, .automatic])
    func undoIsGoneAfterTheNextLetter(_ mode: CorrectionMode) {
        var h = Harness(mode)
        let end = h.type("dkssud")
        _ = h.space(at: end)
        _ = h.signal(.hangul)
        h.type("r", at: end + 1, mode: .hangul)
        #expect(h.policy.backspace() == .none)
    }

    /// The model loads when the server starts; until then nothing is corrected and
    /// the reason is not mistaken for "the detector kept the word".
    @Test(arguments: [CorrectionMode.manual, .automatic])
    func anUnreadyDetectorIsReportedAsSuch(_ mode: CorrectionMode) {
        var h = Harness(mode)
        h.judge.isReady = false
        let end = h.type("dkssud")
        let decision = mode == .automatic ? h.space(at: end) : h.signal(.hangul)
        #expect(decision == .skipped(.detectorNotReady))
        #expect(h.judge.asked.isEmpty)
    }

    /// The reason belongs to one decision; the next switch has nothing to report.
    @Test func aReasonIsReportedOnce() {
        var h = Harness(.manual)
        h.type("dks1")
        #expect(h.signal(.hangul) == .skipped(.dropped(.notALetter)))
        #expect(h.signal(.hangul) == .none)
    }

    /// Off is silent: no tracking, no judge, nothing to log.
    @Test func offNeverCorrects() {
        var h = Harness(.off)
        let end = h.type("dkssud")
        #expect(h.space(at: end) == .none)
        #expect(h.signal(.hangul) == .none)
        #expect(h.judge.asked.isEmpty)
    }

    enum Exclusion: CaseIterable, Sendable { case secureInput, appExcluded, cannotReplace }

    @Test(arguments: [CorrectionMode.manual, .automatic], Exclusion.allCases)
    func excludedContextsNeverCorrect(_ mode: CorrectionMode, _ exclusion: Exclusion) {
        var h = Harness(mode)
        let reason: CorrectionSkip
        switch exclusion {
        case .secureInput: h.environment.secureInput = true; reason = .secureInput
        case .appExcluded: h.environment.appExcluded = true; reason = .appExcluded
        case .cannotReplace: h.environment.cannotReplace = true; reason = .cannotReplace
        }
        let end = h.type("dkssud")
        let decision = mode == .automatic ? h.space(at: end) : h.signal(.hangul)
        #expect(decision == .skipped(reason))
        #expect(h.judge.asked.isEmpty)
    }

    /// A secure field is reported before the app or the client capability.
    @Test func secureInputIsTheFirstReason() {
        var h = Harness(.manual)
        h.environment.secureInput = true
        h.environment.appExcluded = true
        h.environment.cannotReplace = true
        h.type("dkssud")
        #expect(h.signal(.hangul) == .skipped(.secureInput))
    }

    // MARK: word tracking

    /// Never treat a suffix of an identifier as a word.
    @Test func aWordMustStartAtAWordBoundary() {
        var h = Harness(.manual)
        for (offset, key) in "dkssud".enumerated() {
            _ = h.policy.letter(key, caret: 5 + offset, atWordStart: false, mode: .latin, environment: h.environment)
        }
        #expect(h.signal(.hangul) == .skipped(.dropped(.notAtWordStart)))
    }

    @Test func aCaretJumpBreaksTheWord() {
        var h = Harness(.manual)
        h.type("dks")
        for (offset, key) in "sud".enumerated() { // not contiguous and not a word start
            _ = h.policy.letter(key, caret: 10 + offset, atWordStart: false, mode: .latin, environment: h.environment)
        }
        #expect(h.signal(.hangul) == .skipped(.dropped(.caretMoved)))
    }

    @Test func overlongWordsAreNotCandidates() {
        var h = Harness(.manual)
        h.judge.corrections[String(repeating: "r", count: CorrectionPolicy.maximumWordLength + 1)] = "ㄱ"
        h.type(String(repeating: "r", count: CorrectionPolicy.maximumWordLength + 5))
        #expect(h.signal(.hangul) == .skipped(.dropped(.tooLong)))
    }

    @Test func digitsAndPunctuationAreNotWordLetters() {
        var h = Harness(.manual)
        h.type("dks1")
        #expect(h.signal(.hangul) == .skipped(.dropped(.notALetter)))
    }
}
