import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// Stands in for the language detector: exact words only.
private final class FakeJudge: CorrectionJudging {
    var isReady = true
    var corrections = ["dkssud": "안녕", "rk": "가"]
    var asked: [String] = []
    func hangul(for word: String) -> String? {
        asked.append(word)
        return corrections[word]
    }
}

/// Automatic correction (ADR 0064): a Latin-mode word is judged at Space.
/// Positions are UTF-16 offsets in the document.
private struct Harness {
    let judge = FakeJudge()
    var policy: CorrectionPolicy
    var environment: CorrectionEnvironment

    init(_ mode: CorrectionMode = .automatic) {
        policy = CorrectionPolicy(judge: judge)
        environment = CorrectionEnvironment(mode: mode)
    }

    /// Types letters from `start` (a word start) and returns the next caret.
    @discardableResult
    mutating func type(_ word: String, at start: Int = 0, mode: ProbeSession.Mode = .latin) -> Int {
        var caret = start
        for key in word {
            _ = policy.letter(key, caret: caret, atWordStart: caret == start, mode: mode, environment: environment)
            caret += 1
        }
        return caret
    }

    mutating func space(at caret: Int, mode: ProbeSession.Mode = .latin) -> CorrectionDecision {
        policy.space(caret: caret, mode: mode, environment: environment)
    }

    mutating func signal(_ mode: ProbeSession.Mode?) -> CorrectionDecision {
        policy.modeSignal(to: mode, environment: environment)
    }
}

@Suite("Correction policy (ADR 0064, automatic)")
struct CorrectionPolicyTests {
    @Test func automaticCorrectsAtSpaceAndSelectsHangul() {
        var h = Harness()
        let end = h.type("dkssud", at: 2)
        #expect(h.space(at: end) == .correct(CorrectionEdit(location: 2, original: "dkssud ", replacement: "안녕 "), selectHangul: true))
        #expect(h.judge.asked == ["dkssud"])
    }

    /// ADR 0068: the user's mode switch is not a fix request any more; a switch
    /// only cancels automatic work (ADR 0058).
    @Test(arguments: [ProbeSession.Mode.hangul, .latin, nil])
    func aSwitchNeverCorrects(_ target: ProbeSession.Mode?) {
        var h = Harness()
        h.type("dkssud")
        #expect(h.signal(target) == .skipped(.externalSwitch))
        #expect(h.signal(target) == .none)
        #expect(h.judge.asked.isEmpty)
    }

    /// Manual mode is the shortcut only (ADR 0068): nothing is tracked or judged here.
    @Test(arguments: [CorrectionMode.manual, .off])
    func onlyAutomaticTracksWords(_ mode: CorrectionMode) {
        var h = Harness(mode)
        let end = h.type("dkssud")
        #expect(!h.policy.isTrackingWord)
        #expect(h.space(at: end) == .none)
        #expect(h.signal(.hangul) == .none)
        #expect(h.judge.asked.isEmpty)
    }

    @Test func hangulModeWordsAreNotJudged() {
        var h = Harness()
        let end = h.type("hello", mode: .hangul)
        #expect(h.space(at: end, mode: .hangul) == .none)
        #expect(h.judge.asked.isEmpty)
    }

    /// Undo puts back the word without the Space and the Latin mode; the same
    /// word is not corrected again at the next Space (INPUT_METHOD_DESIGN §5).
    @Test func undoRestoresLatinAndIsNotRepeated() {
        var h = Harness()
        let end = h.type("dkssud")
        guard case .correct = h.space(at: end) else { Issue.record("expected a correction"); return }
        let undo = CorrectionEdit(location: 0, original: "dkssud", replacement: "안녕 ")
        #expect(h.policy.backspace() == .undo(undo, selectLatin: true))
        #expect(h.space(at: end) == .skipped(.alreadyUndone))
    }

    @Test func externalSwitchCancelsTheUndo() {
        var h = Harness()
        let end = h.type("dkssud")
        _ = h.space(at: end)
        #expect(h.signal(.hangul) == .skipped(.externalSwitch))
        #expect(h.policy.backspace() == .none)
    }

    @Test func realEnglishIsKept() {
        var h = Harness()
        let end = h.type("hello")
        #expect(h.space(at: end) == .skipped(.notMistyped))
        // The decision is made once; a second Space is just a Space.
        #expect(h.space(at: end + 1) == .none)
    }

    @Test func undoIsOnlyImmediate() {
        var h = Harness()
        let end = h.type("dkssud")
        _ = h.space(at: end)
        h.policy.interrupt(.cursorMoved)
        #expect(h.policy.backspace() == .none)
    }

    @Test func undoIsGoneAfterTheNextLetter() {
        var h = Harness()
        let end = h.type("dkssud")
        _ = h.space(at: end)
        h.type("r", at: end + 1, mode: .hangul)
        #expect(h.policy.backspace() == .none)
    }

    // MARK: false positives (ADR 0065)

    @Test func anUndoneWordIsNotCorrectedAgain() {
        var h = Harness()
        let end = h.type("dkssud")
        _ = h.space(at: end)
        guard case .undo = h.policy.backspace() else { Issue.record("expected an undo"); return }
        h.policy.interrupt(.otherKey)
        let next = h.type("dkssud", at: 20)
        #expect(h.space(at: next) == .skipped(.alreadyUndone))
        let other = h.type("rk", at: 40)
        if case .correct = h.space(at: other) {} else { Issue.record("another word must still be corrected") }
    }

    @Test func undoneWordsAreBounded() {
        var h = Harness()
        func word(_ index: Int) -> String {
            String(String(index, radix: 26).map { Character(UnicodeScalar(($0.wholeNumberValue ?? Int($0.asciiValue! - 87)) + 97)!) })
        }
        let count = CorrectionPolicy.undoneWordLimit + 1
        for index in 0..<count {
            let text = "q" + word(index)
            h.judge.corrections[text] = "가"
            let end = h.type(text, at: index * 100)
            _ = h.space(at: end)
            _ = h.policy.backspace()
            h.policy.interrupt(.otherKey)
        }
        let first = h.type("q" + word(0), at: 1_000_000)
        #expect(h.space(at: first) == .correct(CorrectionEdit(location: 1_000_000, original: "q" + word(0) + " ", replacement: "가 "), selectHangul: true))
        h.policy.interrupt(.otherKey)
        let last = h.type("q" + word(count - 1), at: 2_000_000)
        #expect(h.space(at: last) == .skipped(.alreadyUndone))
    }

    @Test func ignoredWordsAreNeverCorrected() {
        var h = Harness()
        h.environment.ignoredWords = ["dkssud"]
        let end = h.type("dkssud")
        #expect(h.space(at: end) == .skipped(.ignoredWord))
        #expect(h.judge.asked.isEmpty)
    }

    @Test func skipReasonsHaveShortLogNames() {
        #expect(CorrectionSkip.notMistyped.logName == "notMistyped")
        #expect(CorrectionSkip.dropped(.notAtWordStart).logName == "dropped.notAtWordStart")
        #expect(CorrectionSkip.dropped(.interrupted(.cursorMoved)).logName == "dropped.interrupted.cursorMoved")
    }

    @Test func backspaceInsideAWordDropsIt() {
        var h = Harness()
        let end = h.type("dkssudd")
        #expect(h.policy.backspace() == .none)
        #expect(h.space(at: end - 1) == .skipped(.dropped(.edited)))
    }

    @Test func anUnreadyDetectorIsReportedAsSuch() {
        var h = Harness()
        h.judge.isReady = false
        let end = h.type("dkssud")
        #expect(h.space(at: end) == .skipped(.detectorNotReady))
        #expect(h.judge.asked.isEmpty)
    }

    enum Exclusion: CaseIterable, Sendable { case secureInput, appExcluded, cannotReplace }

    @Test(arguments: Exclusion.allCases)
    func excludedContextsNeverCorrect(_ exclusion: Exclusion) {
        var h = Harness()
        let reason: CorrectionSkip
        switch exclusion {
        case .secureInput: h.environment.secureInput = true; reason = .secureInput
        case .appExcluded: h.environment.appExcluded = true; reason = .appExcluded
        case .cannotReplace: h.environment.cannotReplace = true; reason = .cannotReplace
        }
        let end = h.type("dkssud")
        #expect(h.space(at: end) == .skipped(reason))
        #expect(h.judge.asked.isEmpty)
    }

    @Test func secureInputIsTheFirstReason() {
        var h = Harness()
        h.environment.secureInput = true
        h.environment.appExcluded = true
        h.environment.cannotReplace = true
        let end = h.type("dkssud")
        #expect(h.space(at: end) == .skipped(.secureInput))
    }

    // MARK: word tracking

    @Test func aWordMustStartAtAWordBoundary() {
        var h = Harness()
        for (offset, key) in "dkssud".enumerated() {
            _ = h.policy.letter(key, caret: 5 + offset, atWordStart: false, mode: .latin, environment: h.environment)
        }
        #expect(h.space(at: 11) == .skipped(.dropped(.notAtWordStart)))
    }

    @Test func aCaretJumpBreaksTheWord() {
        var h = Harness()
        h.type("dks")
        for (offset, key) in "sud".enumerated() {
            _ = h.policy.letter(key, caret: 10 + offset, atWordStart: false, mode: .latin, environment: h.environment)
        }
        #expect(h.space(at: 13) == .skipped(.dropped(.caretMoved)))
    }

    /// The word-start check queries the client, so it is asked only for a new word.
    @Test func theWordStartIsAskedOnlyWhenNeeded() {
        var h = Harness()
        var asked = 0
        for (offset, key) in "dkssud".enumerated() {
            _ = h.policy.letter(key, caret: offset, atWordStart: { asked += 1; return offset == 0 }(), mode: .latin,
                                environment: h.environment)
        }
        #expect(asked == 1)
    }

    @Test func overlongWordsAreNotCandidates() {
        var h = Harness()
        let end = h.type(String(repeating: "r", count: CorrectionPolicy.maximumWordLength + 5))
        #expect(h.space(at: end) == .skipped(.dropped(.tooLong)))
    }

    @Test(arguments: ["api1", "https://a", "dkssud!", "dks_sud"])
    func identifierLikeInputIsNotACandidate(_ input: String) {
        var h = Harness()
        h.judge.corrections[input] = "x"
        let end = h.type(input)
        #expect(h.space(at: end) == .skipped(.dropped(.notALetter)))
        #expect(h.judge.asked.isEmpty)
    }
}
