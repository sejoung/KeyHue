import KeyHueCore

/// The wrong-language detector (ADR 0040–0042) as the correction judge (ADR 0064).
/// Manual uses the detector's own thresholds, measured for the warning, in both
/// directions (ADR 0067). Automatic replaces text without the user's switch, uses
/// stricter ones and corrects only Latin-mode words.
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

    public func replacement(for keys: String, typedIn: ProbeSession.Mode, mode: CorrectionMode) -> String? {
        switch (mode, typedIn) {
        case (.off, _), (.automatic, .hangul):
            return nil
        case (.manual, .latin), (.automatic, .latin):
            let detector = mode == .manual ? manual : automatic
            guard case .meantHangul(let text) = detector.judge(keys: keys, typedIn: .latin) else { return nil }
            return text
        case (.manual, .hangul):
            guard case .meantLatin(let text) = manual.judge(keys: keys, typedIn: .hangul) else { return nil }
            return text
        }
    }
}
