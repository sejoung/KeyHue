import Foundation

/// 영어 단어의 앞부분(접두사)인지 본다(ADR 0042). 정렬한 단어 목록에서 이분 탐색한다.
/// 모든 접두사를 집합으로 만들면 수백만 개가 되므로 단어 목록만 들고 있는다.
public struct EnglishPrefixIndex: Sendable {
    private let words: [String]

    public init<S: Sequence>(_ words: S) where S.Element == String {
        self.words = Array(Set(words.map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    public var count: Int { words.count }

    /// 접두사로 쓸 단어를 읽는다(ADR 0042): 줄마다 단어 하나인 목록 파일과, 명령어 폴더의 실행 파일 이름.
    /// 명령어(dirname, kubectl)는 사전에 없지만 영문 모드로 치는 단어라, 치는 중에 한글로 잘못 알리지 않게 한다.
    /// 파일 이름만 읽는다. 없는 파일·폴더는 건너뛴다.
    public static func loadWords(wordLists: [String], commandDirectories: [String]) -> [String] {
        var words: [String] = []
        for path in wordLists {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            words += text.split(whereSeparator: \.isNewline).map(String.init)
        }
        for directory in commandDirectories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            words += names.filter { name in !name.isEmpty && name.allSatisfy { $0.isASCII && $0.isLetter } }
        }
        return words
    }

    /// 앱과 측정이 쓰는 기본값. 시스템 단어 목록과, 시스템·Homebrew 명령어 폴더.
    public static let systemWordLists = ["/usr/share/dict/words"]
    public static let commandDirectories = ["/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/local/bin", "/opt/homebrew/bin"]

    /// 이 글자들로 시작하는 단어가 있다(대소문자 구분 없음).
    public func hasWord(withPrefix prefix: String) -> Bool {
        let prefix = prefix.lowercased()
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid] < prefix { low = mid + 1 } else { high = mid }
        }
        return low < words.count && words[low].hasPrefix(prefix)
    }
}

/// 치는 중인 단어의 앞부분으로 미리 판정한다(ADR 0042). 단어 끝(공백) 판정(`MistypeDetector.judge`)보다 근거가 적으므로
/// 두 언어의 비대칭을 쓴다.
///
/// - 한글 모드 → 영어: 모음이 음절이 되지 못하고 **확정**됐다(ㅗ디 = he). 제대로 친 한글에서는 ㅠㅠ 같은 표현 말고는 나오지 않는다.
///   오타(아ㅏ)와 구분하려고 키가 영어 단어의 앞부분이어야 한다.
/// - 영문 모드 → 한글: 이 글자로 시작하는 영어 단어가 없고(dkss), 두벌식으로는 낱자 없이 음절이 되고 한국어답다.
///   의미 없는 Shift(고유명사 첫 글자)가 있으면 보지 않는다.
/// 마지막 글자는 다음 키에 따라 바뀌므로(받침이 넘어가거나 ㅗ가 ㅘ가 된다) 확정된 글자와 마지막 음절의 초성·중성만 본다.
public struct EarlyMistypeFeatures: Equatable, Sendable {
    public let keys: String
    public let hangul: Dubeolsik.Composition
    public let isEnglishPrefix: Bool
    public let hasPlainShift: Bool
    /// 확정된 글자 + 마지막 음절의 받침을 뺀 부분이 모두 음절일 때의 한국어 점수(끝 경계 없음). 아니면 nil.
    public let stableScore: Double?
    /// 확정된 글자 중 음절이 되지 못한 모음이 있다.
    public let hasCommittedLooseVowel: Bool
}

extension MistypeDetector {
    public struct EarlyThresholds: Equatable, Sendable {
        /// 영문 모드: 이만큼 친 뒤부터 본다.
        public var latinMinimumKeys: Int
        /// 영문 모드 → 한글: 한국어 점수(끝 경계 없음)가 이 값 이상.
        public var hangulAccept: Double
        /// 한글 모드: 이만큼 친 뒤부터 본다.
        public var hangulMinimumKeys: Int

        public init(latinMinimumKeys: Int = 3, hangulAccept: Double = -2.5, hangulMinimumKeys: Int = 2) {
            self.latinMinimumKeys = latinMinimumKeys
            self.hangulAccept = hangulAccept
            self.hangulMinimumKeys = hangulMinimumKeys
        }
    }

    /// 치는 중인 단어의 앞부분을 판정한다. 영어 접두사가 없으면 판정하지 않는다.
    public func judgeEarly(keys: String, typedIn mode: TypingMode) -> MistypeVerdict {
        guard let prefixes, let features = earlyFeatures(keys: keys, prefixes: prefixes) else { return .keep }
        return Self.judgeEarly(features, typedIn: mode, thresholds: earlyThresholds)
    }

    public func earlyFeatures(keys: String, prefixes: EnglishPrefixIndex) -> EarlyMistypeFeatures? {
        let hangul = Dubeolsik.compose(keys: keys)
        guard hangul.isValid else { return nil }
        return EarlyMistypeFeatures(
            keys: keys,
            hangul: hangul,
            isEnglishPrefix: Self.hasEnglishCasing(keys) && prefixes.hasWord(withPrefix: keys),
            hasPlainShift: keys.contains(where: Dubeolsik.isPlainShift),
            stableScore: Self.stableText(hangul).flatMap { model.score($0, isPrefix: true) },
            hasCommittedLooseVowel: hangul.committedUnits.contains(where: \.isLooseVowel)
        )
    }

    public static func judgeEarly(_ f: EarlyMistypeFeatures, typedIn mode: TypingMode, thresholds t: EarlyThresholds) -> MistypeVerdict {
        switch mode {
        case .latin:
            guard f.keys.count >= t.latinMinimumKeys, !f.hasPlainShift, !f.isEnglishPrefix,
                  let score = f.stableScore, score >= t.hangulAccept else { return .keep }
            return .meantHangul(f.hangul.text)
        case .hangul:
            guard f.keys.count >= t.hangulMinimumKeys, f.hasCommittedLooseVowel, f.isEnglishPrefix,
                  !isJamoExpression(f.hangul) else { return .keep }
            return .meantLatin(f.keys)
        }
    }

    /// 다음 키가 와도 바뀌지 않는 음절들: 확정된 음절 + 마지막 음절의 초성·중성(받침은 다음 음절로 넘어갈 수 있다).
    /// 확정된 글자에 낱자가 있거나, 마지막 글자가 낱자 모음이면 nil(음절이 될 수 없다).
    /// 마지막 글자가 낱자 자음이면 다음 음절의 초성이 될 수 있으므로 빼고 본다.
    static func stableText(_ c: Dubeolsik.Composition) -> String? {
        var text = ""
        for unit in c.committedUnits {
            guard case .syllable(let syllable) = unit else { return nil }
            text.append(syllable)
        }
        switch c.units.last {
        case .syllable(let syllable)?:
            let value = Int(syllable.unicodeScalars.first!.value) - 0xAC00
            text.append(Character(UnicodeScalar(0xAC00 + value - value % 28)!))
        case .loose(let jamo)? where Dubeolsik.isVowel(jamo):
            return nil
        default:
            break
        }
        return text.isEmpty ? nil : text
    }
}
