import KeyHueCore

/// The wrong-language detector (ADR 0040–0042) as the correction judge (ADR 0064).
/// Manual uses the detector's own thresholds, measured for the warning. Automatic
/// replaces text without the user's switch and uses stricter ones.
public final class DetectorCorrectionJudge: CorrectionJudging {
    /// Measured with Tests/perf/mistype-eval.sh (ADR 0064, docs/adr/data/0064-mistype-eval.md):
    /// four keys or more halves the false positives of the warning's three, for about
    /// 3–5 points of detection. Keeping −2.75 instead of the tool's −3.00 suggestion
    /// costs almost no detection and has a third of the news/wiki false positives.
    public static let automaticThresholds = MistypeDetector.Thresholds(latinMinimumKeys: 4, hangulAccept: -2.75)

    private let manual: MistypeDetector
    private let automatic: MistypeDetector

    public init(detector: MistypeDetector, automaticThresholds: MistypeDetector.Thresholds = automaticThresholds) {
        manual = detector
        var automatic = detector
        automatic.thresholds = automaticThresholds
        self.automatic = automatic
    }

    /// Built only after the model and lexicon are loaded.
    public var isReady: Bool { true }

    public func hangul(for word: String, mode: CorrectionMode) -> String? {
        let detector: MistypeDetector
        switch mode {
        case .off: return nil
        case .manual: detector = manual
        case .automatic: detector = automatic
        }
        guard case .meantHangul(let text) = detector.judge(keys: word, typedIn: .latin) else { return nil }
        return text
    }
}
