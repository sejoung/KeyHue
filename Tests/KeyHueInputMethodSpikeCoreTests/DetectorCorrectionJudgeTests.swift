import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0064: the wrong-language detector (ADR 0040–0042) decides which Latin-mode
/// words automatic correction changes. Shortcut fixes are never judged (ADR 0068).
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

    private func judge(_ thresholds: MistypeDetector.Thresholds = DetectorCorrectionJudge.automaticThresholds) -> DetectorCorrectionJudge {
        DetectorCorrectionJudge(detector: MistypeDetector(lexicon: Self.lexicon, model: Self.model), thresholds: thresholds)
    }

    @Test func koreanTypedOnTheLatinLayoutIsCorrected() {
        #expect(judge().hangul(for: "dkssudgktpdy") == "안녕하세요")
        #expect(judge().hangul(for: "dlqfurrl") == "입력기")
    }

    @Test func englishWordsAreKept() {
        #expect(judge().hangul(for: "hello") == nil)
        #expect(judge().hangul(for: "input") == nil)
        #expect(judge().hangul(for: "API") == nil)
    }

    /// A Shift that does nothing on Dubeolsik (a capitalized name) means English.
    @Test func plainShiftIsKept() {
        #expect(judge().hangul(for: "Dkssud") == nil)
    }

    @Test func theThresholdsAreUsed() {
        var strict = MistypeDetector.Thresholds()
        strict.latinMinimumKeys = 7
        #expect(judge(strict).hangul(for: "dkssud") == nil)
        #expect(judge().hangul(for: "dkssud") == "안녕")
    }

    /// Automatic replaces text without the user asking, so it is never looser
    /// than the warning defaults.
    @Test func automaticIsAtLeastAsStrictAsTheWarning() {
        let warning = MistypeDetector.Thresholds()
        let automatic = DetectorCorrectionJudge.automaticThresholds
        #expect(automatic.latinMinimumKeys >= warning.latinMinimumKeys)
        #expect(automatic.hangulAccept >= warning.hangulAccept)
    }
}
