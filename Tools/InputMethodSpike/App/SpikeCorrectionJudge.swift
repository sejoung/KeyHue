import Foundation
import KeyHueCore
import KeyHueInputMethodSpikeCore
import KeyHueSystemLexicon

/// One detector per server process (ADR 0064). The model is read off the main
/// thread when a correction client first activates, never in the key path
/// (INPUT_METHOD_DESIGN §7). Until then the policy skips with `.detectorNotReady`.
/// Used only from the main thread, like every IMK callback here.
final class SpikeCorrectionJudge: CorrectionJudging, @unchecked Sendable {
    static let shared = SpikeCorrectionJudge()
    static let modelResource = (name: "hangul-syllables", extension: "tsv", subdirectory: "Mistype")

    private var loaded: DetectorCorrectionJudge?
    private var loading = false

    var isReady: Bool { loaded != nil }

    func hangul(for word: String) -> String? {
        loaded?.hangul(for: word)
    }

    func load() {
        guard loaded == nil, !loading else { return }
        loading = true
        let started = ProcessInfo.processInfo.systemUptime
        let url = Bundle.main.url(forResource: Self.modelResource.name, withExtension: Self.modelResource.extension,
                                  subdirectory: Self.modelResource.subdirectory)
        DispatchQueue.global(qos: .utility).async {
            let model = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { HangulSyllableModel(serialized: $0) }
            let lexicon = SystemEnglishLexicon()
            DispatchQueue.main.async {
                self.loading = false
                guard let model else {
                    SpikeLog.error("correction detector model missing")
                    return
                }
                self.loaded = DetectorCorrectionJudge(detector: MistypeDetector(lexicon: lexicon, model: model))
                SpikeLog.notice("correction detector ready ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            }
        }
    }
}
