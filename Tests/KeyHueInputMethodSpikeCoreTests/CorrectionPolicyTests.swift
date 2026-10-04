import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// Stands in for the language detector (step 3): exact words only.
private final class FakeJudge: CorrectionJudging {
    var isReady = true
    /// Latin-mode keys meant as Korean.
    var corrections = ["dkssud": "안녕", "rk": "가"]
    /// Hangul-mode keys meant as English (ADR 0067).
    var latinWords: Set<String> = ["hello", "rk"]
    var asked: [(String, CorrectionMode)] = []
    var askedTypedIn: [ProbeSession.Mode] = []
    func replacement(for keys: String, typedIn: ProbeSession.Mode, mode: CorrectionMode) -> String? {
        asked.append((keys, mode))
        askedTypedIn.append(typedIn)
        switch typedIn {
        case .latin: return corrections[keys]
        case .hangul: return latinWords.contains(keys) ? keys : nil
        }
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

    /// Types keys in Hangul mode from `start`. The caret before each key is after
    /// the text composed so far, as the client shows it (ADR 0067).
    @discardableResult
    mutating func typeHangul(_ keys: String, at start: Int = 0) -> Int {
        var typed = ""
        for key in keys {
            let caret = start + Dubeolsik.compose(keys: typed).text.utf16.count
            _ = policy.letter(key, caret: caret, atWordStart: typed.isEmpty, mode: .hangul, environment: environment)
            typed.append(key)
        }
        return start + Dubeolsik.compose(keys: typed).text.utf16.count
    }

    /// A client that reports no positions (terminals, ADR 0067).
    mutating func typeWithoutPositions(_ word: String, mode: ProbeSession.Mode = .latin, atWordStart: Bool = true) {
        for (offset, key) in word.enumerated() {
            _ = policy.letter(key, caret: nil, atWordStart: atWordStart && offset == 0, mode: mode, environment: environment)
        }
    }

    mutating func space(at caret: Int?, mode: ProbeSession.Mode = .latin) -> CorrectionDecision {
        policy.space(caret: caret, mode: mode, environment: environment)
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

    /// The word-start check queries the client, so the policy asks only when it
    /// needs to: at a new word, and after the caret jumped, never while a word
    /// continues. A jump to a word start begins the new word there.
    @Test func theWordStartIsAskedOnlyWhenNeeded() {
        var h = Harness(.manual)
        var asked = 0
        func letter(_ key: Character, at caret: Int, start: Bool) {
            _ = h.policy.letter(key, caret: caret, atWordStart: { asked += 1; return start }(), mode: .latin, environment: h.environment)
        }
        for (offset, key) in "dks".enumerated() { letter(key, at: offset, start: offset == 0) }
        #expect(asked == 1)
        for (offset, key) in "dkssud".enumerated() { letter(key, at: 10 + offset, start: offset == 0) }
        #expect(asked == 2)
        #expect(h.signal(.hangul) == .correct(CorrectionEdit(location: 10, original: "dkssud", replacement: "안녕"), selectHangul: false))
    }

    // MARK: false positives (ADR 0065)

    /// An immediate undo is the user's "this was wrong": the same word is not
    /// corrected again while the input method runs, wherever it is typed.
    @Test(arguments: [CorrectionMode.manual, .automatic])
    func anUndoneWordIsNotCorrectedAgain(_ mode: CorrectionMode) {
        var h = Harness(mode)
        let end = h.type("dkssud")
        if mode == .automatic { _ = h.space(at: end) } else { _ = h.signal(.hangul) }
        guard case .undo = h.policy.backspace() else { Issue.record("expected an undo"); return }
        h.policy.interrupt(.otherKey)
        let next = h.type("dkssud", at: 20)
        let decision = mode == .automatic ? h.space(at: next) : h.signal(.hangul)
        #expect(decision == .skipped(.alreadyUndone))
        // Other words are still corrected.
        let other = h.type("rk", at: 40)
        let otherDecision = mode == .automatic ? h.space(at: other) : h.signal(.hangul)
        if case .correct = otherDecision {} else { Issue.record("another word must still be corrected") }
    }

    /// Only the most recent undone words are kept, in memory.
    @Test func undoneWordsAreBounded() {
        var h = Harness(.manual)
        func word(_ index: Int) -> String {
            String(String(index, radix: 26).map { Character(UnicodeScalar(($0.wholeNumberValue ?? Int($0.asciiValue! - 87)) + 97)!) })
        }
        let count = CorrectionPolicy.undoneWordLimit + 1
        for index in 0..<count {
            let text = "q" + word(index)
            h.judge.corrections[text] = "가"
            h.type(text, at: index * 100)
            _ = h.signal(.hangul)
            _ = h.policy.backspace()
            h.policy.interrupt(.otherKey)
        }
        h.type("q" + word(0), at: 1_000_000)
        #expect(h.signal(.hangul) == .correct(CorrectionEdit(location: 1_000_000, original: "q" + word(0), replacement: "가"), selectHangul: false))
        h.policy.interrupt(.otherKey)
        h.type("q" + word(count - 1), at: 2_000_000)
        #expect(h.signal(.hangul) == .skipped(.alreadyUndone))
    }

    /// The user's exception words and the shipped reported words are never
    /// corrected, and the detector is not asked.
    @Test(arguments: [CorrectionMode.manual, .automatic])
    func ignoredWordsAreNeverCorrected(_ mode: CorrectionMode) {
        var h = Harness(mode)
        h.environment.ignoredWords = ["dkssud"]
        let end = h.type("dkssud")
        let decision = mode == .automatic ? h.space(at: end) : h.signal(.hangul)
        #expect(decision == .skipped(.ignoredWord))
        #expect(h.judge.asked.isEmpty)
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

    // MARK: manual, the other direction (ADR 0067)

    @Test func manualCorrectsEnglishTypedInHangulWhenTheUserSwitchesToLatin() {
        var h = Harness(.manual)
        let end = h.typeHangul("hello", at: 3)
        #expect(h.space(at: end, mode: .hangul) == .none)
        let edit = CorrectionEdit(location: 3, original: "ㅗ디ㅣㅐ ", replacement: "hello ")
        #expect(h.signal(.latin) == .correct(edit, selectHangul: false))
        #expect(h.judge.askedTypedIn == [.hangul])
        #expect(h.judge.asked.map(\.1) == [.manual])
    }

    @Test func manualCorrectsAHangulModeWordStillBeingTyped() {
        var h = Harness(.manual)
        h.typeHangul("hello")
        #expect(h.policy.isTrackingWord)
        #expect(h.signal(.latin) == .correct(CorrectionEdit(location: 0, original: "ㅗ디ㅣㅐ", replacement: "hello"), selectHangul: false))
    }

    /// Syllables change length while they compose; the caret follows the composed text.
    @Test func composedSyllablesKeepTheWordContiguous() {
        var h = Harness(.manual)
        h.judge.latinWords.insert("dkssud")
        h.typeHangul("dkssud", at: 5)
        #expect(h.signal(.latin) == .correct(CorrectionEdit(location: 5, original: "안녕", replacement: "dkssud"), selectHangul: false))
    }

    @Test func koreanTypedInHangulModeIsKept() {
        var h = Harness(.manual)
        h.typeHangul("dkssud")
        #expect(h.signal(.latin) == .skipped(.notMistyped))
    }

    /// A switch to the mode the word was typed in, or to another source, is not a fix request.
    @Test(arguments: [ProbeSession.Mode.hangul, nil])
    func switchingAnywhereButLatinDropsAHangulModeWord(_ target: ProbeSession.Mode?) {
        var h = Harness(.manual)
        h.typeHangul("hello")
        #expect(h.signal(target) == .none)
        #expect(h.signal(.latin) == .skipped(.dropped(.switchedAway)))
        #expect(h.judge.asked.isEmpty)
    }

    @Test func undoOfAHangulModeWordRestoresTheHangul() {
        var h = Harness(.manual)
        h.typeHangul("hello")
        let edit = CorrectionEdit(location: 0, original: "ㅗ디ㅣㅐ", replacement: "hello")
        #expect(h.signal(.latin) == .correct(edit, selectHangul: false))
        #expect(h.policy.backspace() == .undo(edit, selectLatin: false))
        h.policy.interrupt(.otherKey)
        h.typeHangul("hello", at: 20)
        #expect(h.signal(.latin) == .skipped(.alreadyUndone))
    }

    /// Exception words are what the user saw: Hangul for a Hangul-mode word.
    @Test func ignoredWordsMatchTheVisibleText() {
        var h = Harness(.manual)
        h.environment.ignoredWords = ["ㅗ디ㅣㅐ"]
        h.typeHangul("hello")
        #expect(h.signal(.latin) == .skipped(.ignoredWord))
        #expect(h.judge.asked.isEmpty)
    }

    /// The same keys mean different things in each mode; an undo in one direction
    /// does not block the other.
    @Test func undoneWordsAreKeptPerVisibleText() {
        var h = Harness(.manual)
        h.type("rk")
        _ = h.signal(.hangul)
        _ = h.policy.backspace()
        h.policy.interrupt(.otherKey)
        h.typeHangul("rk", at: 10)
        #expect(h.signal(.latin) == .correct(CorrectionEdit(location: 10, original: "가", replacement: "rk"), selectHangul: false))
    }

    /// Automatic corrects only Latin-mode words at Space; English typed in Hangul
    /// mode is corrected only on the user's switch.
    @Test func automaticNeverCorrectsHangulModeWords() {
        var h = Harness(.automatic)
        let end = h.typeHangul("hello")
        #expect(h.space(at: end, mode: .hangul) == .none)
        #expect(h.signal(.latin) == .none)
        #expect(h.judge.asked.isEmpty)
    }

    // MARK: clients without positions (terminals, ADR 0067)

    @Test func aClientWithoutPositionsIsTrackedByKeys() {
        var h = Harness(.manual)
        h.typeWithoutPositions("dkssud")
        #expect(h.space(at: nil) == .none)
        #expect(h.signal(.hangul) == .correct(CorrectionEdit(location: 0, original: "dkssud ", replacement: "안녕 "), selectHangul: false))
    }

    @Test func aClientWithoutPositionsStillNeedsAWordStart() {
        var h = Harness(.manual)
        h.typeWithoutPositions("dkssud", atWordStart: false)
        #expect(h.signal(.hangul) == .skipped(.dropped(.notAtWordStart)))
    }

    @Test func aClientWithoutPositionsCorrectsBothDirections() {
        var h = Harness(.manual)
        h.typeWithoutPositions("hello", mode: .hangul)
        #expect(h.signal(.latin) == .correct(CorrectionEdit(location: 0, original: "ㅗ디ㅣㅐ", replacement: "hello"), selectHangul: false))
    }

    /// Positions that appear or disappear inside one word mean the client changed.
    @Test func losingPositionsInsideAWordDropsIt() {
        var h = Harness(.manual)
        h.type("dks")
        for key in "sud" {
            _ = h.policy.letter(key, caret: nil, atWordStart: false, mode: .latin, environment: h.environment)
        }
        #expect(h.signal(.hangul) == .skipped(.dropped(.caretMoved)))
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

    /// Identifiers, URLs and words with punctuation are never candidates
    /// (INPUT_METHOD_DESIGN §5; the engine no longer filters the fixture itself).
    @Test(arguments: ["api1", "https://a", "dkssud!", "dks_sud"])
    func identifierLikeInputIsNotACandidate(_ input: String) {
        var h = Harness(.manual)
        h.judge.corrections[input] = "x"
        h.type(input)
        #expect(h.signal(.hangul) == .skipped(.dropped(.notALetter)))
        #expect(h.judge.asked.isEmpty)
    }

    @Test func digitsAndPunctuationAreNotWordLetters() {
        var h = Harness(.manual)
        h.type("dks1")
        #expect(h.signal(.hangul) == .skipped(.dropped(.notALetter)))
    }
}
