import Foundation
import KeyHueCore
import KeyHueSystemLexicon

/// 실험적: 잘못된 언어로 친 단어를 찾아 알린다(ADR 0041, 1a단계: 경고만, 입력과 입력 소스는 건드리지 않는다).
///
/// 키보드 모니터의 키 코드를 `MistypeWordTracker`에 넘기고, 판정이 나오면 `onWarning`을 부른다.
/// 치는 중(ADR 0042)과 단어 끝(공백) 모두에서 판정하며, 한 단어에 한 번만 알린다.
/// - 모은 키는 메모리에만 있고 단어마다 지운다. 로그에는 판정 방향만 남기고 단어는 남기지 않는다.
/// - 음절 모델(앱 번들의 Mistype/hangul-syllables.tsv)과 영어 접두사(시스템 단어 목록 + 설치된 명령어 이름)는
///   켤 때 한 번 백그라운드에서 읽는다.
@MainActor
final class WrongLanguageMonitor {
    static let modelResource = (name: "hangul-syllables", extension: "tsv", subdirectory: "Mistype")

    private var tracker: MistypeWordTracker?
    private var isLoading = false
    private(set) var isEnabled = false

    /// (판정, 치는 중에 나온 판정인가). 판정에는 그 언어로 바꾼 글자가 들어 있다(화면에만 보여 준다).
    var onWarning: ((MistypeVerdict, Bool) -> Void)?

    /// 모델 파일을 읽지 못했다(번들이 아닌 실행 등). 이때는 동작하지 않는다.
    private(set) var isModelMissing = false

    private let modelURL: URL?
    private let lexicon: @Sendable () -> EnglishLexicon
    private let prefixWords: @Sendable () -> [String]

    init(
        modelURL: URL? = Bundle.main.url(
            forResource: modelResource.name, withExtension: modelResource.extension, subdirectory: modelResource.subdirectory
        ),
        lexicon: @escaping @Sendable () -> EnglishLexicon = { SystemEnglishLexicon() },
        prefixWords: @escaping @Sendable () -> [String] = {
            EnglishPrefixIndex.loadWords(
                wordLists: EnglishPrefixIndex.systemWordLists,
                commandDirectories: EnglishPrefixIndex.commandDirectories
            )
        }
    ) {
        self.modelURL = modelURL
        self.lexicon = lexicon
        self.prefixWords = prefixWords
    }

    /// 판정할 준비가 됐다(모델을 다 읽었다).
    var isReady: Bool { tracker != nil }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            Task { await prepare() }
        } else {
            tracker?.reset()
        }
    }

    func key(_ key: KeyboardMonitor.KeyDown, sourceID: String?) {
        guard isEnabled, var tracker else { return }
        let mode = key.capsLock ? nil : sourceID.flatMap(MistypeSupport.mode(forSourceID:))
        let mistypeKey = MistypeKeyMap.key(keyCode: key.keyCode, shift: key.shift, otherModifiers: key.otherModifiers)
        let verdict = tracker.key(mistypeKey, mode: mode)
        self.tracker = tracker
        if let verdict {
            let whileTyping = tracker.lastWarningWasWhileTyping
            Log.state.notice("wrong language warning: \(Self.logDescription(verdict))\(whileTyping ? " (while typing)" : "")")
            onWarning?(verdict, whileTyping)
        }
    }

    /// 커서가 움직였을 수 있다(마우스 클릭, 앱 전환). 모으던 단어를 버린다.
    func reset() {
        tracker?.reset()
    }

    /// 로그용. 단어는 남기지 않는다.
    static func logDescription(_ verdict: MistypeVerdict) -> String {
        switch verdict {
        case .keep: return "keep"
        case .meantHangul: return "meant hangul"
        case .meantLatin: return "meant latin"
        }
    }

    /// 모델을 한 번 읽는다(백그라운드). 이미 읽었거나 읽는 중이면 바로 돌아온다.
    func prepare() async {
        guard tracker == nil, !isLoading, !isModelMissing else { return }
        guard let modelURL else {
            isModelMissing = true
            Log.state.error("wrong language model not found in bundle")
            return
        }
        isLoading = true
        let lexicon = self.lexicon
        let prefixWords = self.prefixWords
        let detector = await Task.detached(priority: .utility) { () -> MistypeDetector? in
            guard let text = try? String(contentsOf: modelURL, encoding: .utf8),
                  let model = HangulSyllableModel(serialized: text) else { return nil }
            let words = prefixWords()
            // 접두사를 읽지 못하면 치는 중 판정은 끄고 단어 끝 판정만 한다.
            return MistypeDetector(lexicon: lexicon(), model: model, prefixes: words.isEmpty ? nil : EnglishPrefixIndex(words))
        }.value
        isLoading = false
        guard let detector else {
            isModelMissing = true
            Log.state.error("wrong language model could not be read")
            return
        }
        tracker = MistypeWordTracker(detector: detector)
        Log.state.notice(
            "wrong language model loaded (\(detector.model.bigramCount) bigrams, \(detector.prefixes?.count ?? 0) prefix words)"
        )
    }
}
