import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0064 step 3: the wrong-language detector (ADR 0040–0042) decides which
/// Latin-mode words are Korean. Manual and automatic use separate thresholds.
/// ADR 0067: manual also corrects English typed in Hangul mode.
@Suite("Detector correction judge")
struct DetectorCorrectionJudgeTests {
    static let model: HangulSyllableModel = {
        var model = HangulSyllableModel()
        for word in ["안녕", "안녕하세요", "한글", "입력", "입력기", "오늘", "날씨", "좋다", "하세요", "합니다"] {
            model.train(word: word, count: 20)
        }
        return model
    }()
    static let lexicon = WordListLexicon(["hello", "world", "test", "input", "api"])

    private func judge(automatic: MistypeDetector.Thresholds = DetectorCorrectionJudge.automaticThresholds) -> DetectorCorrectionJudge {
        DetectorCorrectionJudge(detector: MistypeDetector(lexicon: Self.lexicon, model: Self.model), automaticThresholds: automatic)
    }

    @Test(arguments: [CorrectionMode.manual, .automatic])
    func koreanTypedOnTheLatinLayoutIsCorrected(_ mode: CorrectionMode) {
        #expect(judge().meant("dkssudgktpdy", mode: mode) == "안녕하세요")
        #expect(judge().meant("dlqfurrl", mode: mode) == "입력기")
    }

    @Test(arguments: [CorrectionMode.manual, .automatic])
    func englishWordsAreKept(_ mode: CorrectionMode) {
        #expect(judge().meant("hello", mode: mode) == nil)
        #expect(judge().meant("input", mode: mode) == nil)
        #expect(judge().meant("API", mode: mode) == nil)
    }

    /// A Shift that does nothing on Dubeolsik (a capitalized name) means English.
    @Test(arguments: [CorrectionMode.manual, .automatic])
    func plainShiftIsKept(_ mode: CorrectionMode) {
        #expect(judge().meant("Dkssud", mode: mode) == nil)
    }

    @Test func offNeverAsksTheDetector() {
        #expect(judge().meant("dkssudgktpdy", mode: .off) == nil)
    }

    /// Manual keeps the warning's measured thresholds; automatic has its own.
    @Test func eachModeUsesItsOwnThresholds() {
        var strict = MistypeDetector.Thresholds()
        strict.latinMinimumKeys = 7
        let judge = judge(automatic: strict)
        #expect(judge.meant("dkssud", mode: .manual) == "안녕")
        #expect(judge.meant("dkssud", mode: .automatic) == nil)
    }

    // MARK: Hangul mode (ADR 0067)

    @Test func englishTypedInHangulModeIsCorrectedOnTheUsersSwitch() {
        #expect(judge().replacement(for: "hello", typedIn: .hangul, mode: .manual) == "hello")
        #expect(judge().replacement(for: "input", typedIn: .hangul, mode: .manual) == "input")
    }

    @Test func koreanTypedInHangulModeIsKept() {
        #expect(judge().replacement(for: "dkssud", typedIn: .hangul, mode: .manual) == nil)
        #expect(judge().replacement(for: "dlqfurrl", typedIn: .hangul, mode: .manual) == nil)
    }

    /// Automatic corrects at Space without a switch; it stays Latin → Hangul only.
    @Test func automaticNeverCorrectsHangulModeWords() {
        #expect(judge().replacement(for: "hello", typedIn: .hangul, mode: .automatic) == nil)
        #expect(judge().replacement(for: "hello", typedIn: .hangul, mode: .off) == nil)
    }

    /// Automatic replaces text without the user's switch, so it is never looser
    /// than the warning defaults that manual uses.
    @Test func automaticIsAtLeastAsStrictAsManual() {
        let manual = MistypeDetector.Thresholds()
        let automatic = DetectorCorrectionJudge.automaticThresholds
        #expect(automatic.latinMinimumKeys >= manual.latinMinimumKeys)
        #expect(automatic.hangulAccept >= manual.hangulAccept)
    }
}

private extension DetectorCorrectionJudge {
    /// Latin-mode keys, the direction ADR 0064 started with.
    func meant(_ keys: String, mode: CorrectionMode) -> String? {
        replacement(for: keys, typedIn: .latin, mode: mode)
    }
}
