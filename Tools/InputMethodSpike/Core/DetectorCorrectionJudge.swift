import KeyHueCore

/// The wrong-language detector (ADR 0040–0042) as the automatic correction judge
/// (ADR 0064). Automatic replaces text without the user asking and uses stricter
/// thresholds than the warning. Fixes the user asks for with the shortcut are
/// never judged (ADR 0068).
public final class DetectorCorrectionJudge: CorrectionJudging {
    /// Measured with Tests/perf/mistype-eval.sh (ADR 0064, docs/adr/data/0064-mistype-eval.md):
    /// four keys or more halves the false positives of the warning's three, for about
    /// 3–5 points of detection. Keeping −2.75 instead of the tool's −3.00 suggestion
    /// costs almost no detection and has a third of the news/wiki false positives.
    public static let automaticThresholds = MistypeDetector.Thresholds(latinMinimumKeys: 4, hangulAccept: -2.75)

    private let detector: MistypeDetector

    public init(detector: MistypeDetector, thresholds: MistypeDetector.Thresholds = automaticThresholds) {
        var detector = detector
        detector.thresholds = thresholds
        self.detector = detector
    }

    /// Built only after the model and lexicon are loaded.
    public var isReady: Bool { true }

    public func hangul(for word: String) -> String? {
        guard case .meantHangul(let text) = detector.judge(keys: word, typedIn: .latin) else { return nil }
        return text
    }
}
