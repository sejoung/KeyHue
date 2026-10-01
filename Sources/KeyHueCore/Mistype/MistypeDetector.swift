import Foundation

/// 영어 단어 목록. 앱에서는 시스템 사전(NSSpellChecker)으로, 테스트·측정에서는 단어 목록으로 구현한다.
public protocol EnglishLexicon: Sendable {
    func contains(_ word: String) -> Bool
}

/// 단어 목록 기반 사전. 대소문자를 구분하지 않는다.
public struct WordListLexicon: EnglishLexicon, Sendable {
    private let words: Set<String>

    public init<S: Sequence>(_ words: S) where S.Element == String {
        self.words = Set(words.map { $0.lowercased() })
    }

    public var count: Int { words.count }

    public func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }
}

/// 키를 칠 때 선택돼 있던 입력 모드.
public enum TypingMode: String, Sendable, CaseIterable {
    /// ABC·U.S. 같은 QWERTY 영문 배열
    case latin
    /// 한국어 두벌식
    case hangul
}

/// 판정 결과.
public enum MistypeVerdict: Equatable, Sendable {
    /// 그대로 둔다(맞게 쳤거나 확신이 없다).
    case keep
    /// 영문 모드로 쳤지만 한글을 의도한 것 같다. 값은 한글로 바꾼 글자.
    case meantHangul(String)
    /// 한글 모드로 쳤지만 영어를 의도한 것 같다. 값은 영문 글자.
    case meantLatin(String)
}

/// 한 단어의 키 입력을 두 언어로 풀어 본 특징값. 측정 도구가 임계값을 바꿔 가며 다시 판정할 수 있게 따로 둔다.
public struct MistypeFeatures: Equatable, Sendable {
    public let keys: String
    /// 영문으로 읽은 단어(= 키 그대로)
    public let latin: String
    public let latinIsWord: Bool
    /// 두벌식에서 의미 없는 Shift를 눌렀다(영어를 치려던 신호, `Dubeolsik.isPlainShift`).
    public let hasPlainShift: Bool
    /// 두벌식으로 풀었을 때 음절이 되지 못한 모음이 있다(ㅔㅑㅔㄷㄹ먀ㅣ = pipefail).
    public var hasLooseVowel: Bool { hangul.looseJamo.contains(where: Dubeolsik.isVowel) }
    public let hangul: Dubeolsik.Composition
    /// 음절로만 이뤄졌을 때의 한국어 점수(log10, 음절당). 낱자가 있으면 nil.
    public let hangulScore: Double?
}

/// 단어 하나의 키 입력이 잘못된 언어로 쳐졌는지 판정한다(ADR 0040, 0단계: 판정만, 입력은 건드리지 않음).
///
/// - 영문 모드 → 한글 의도: 영어 사전에 없고, 의미 없는 Shift(고유명사 첫 글자 등)가 없고,
///   두벌식으로 풀면 낱자 없이 음절만 나오고, 한국어 점수가 높다.
/// - 한글 모드 → 영어 의도: 영어 사전에 있고, 음절만 나왔다면 한국어 점수가 낮다(`hangulReject`).
///   점수 검사는 2–3타 단어(꺼 = Rj, 앳 = dot)의 오탐을 줄인다(측정: Tests/perf/mistype-eval.sh).
///   사전에 없어도 음절이 되지 못한 모음이 남으면 영어로 본다(`looseVowelMeansLatin`, 명령어·식별자).
///   ㅋㅋㅋ·ㅠㅠ처럼 같은 낱자만 반복한 것과 ㅎㄷㄷ(= gee)·ㅇㅋ 같은 세 타 이하 초성체는 한국어 표현으로 보고 그대로 둔다.
/// 영어 단어는 소문자, 첫 글자만 대문자, 모두 대문자 중 하나여야 한다. 가운데 대문자(wkRn = 자꾸)는
/// 두벌식의 쌍자음·ㅒㅖ이므로 영어로 보지 않는다.
/// 짧은 단어는 양쪽 다 말이 되는 경우가 많아 판정하지 않는다. 방향마다 최소 길이가 다르다.
public struct MistypeDetector: Sendable {
    public struct Thresholds: Equatable, Sendable {
        /// 영문 모드 판정: 이보다 짧은 키 입력은 판정하지 않는다.
        public var latinMinimumKeys: Int
        /// 영문 모드 → 한글: 한국어 점수가 이 값 이상이어야 한다.
        public var hangulAccept: Double
        /// 한글 모드 판정: 이보다 짧은 키 입력은 판정하지 않는다.
        public var hangulMinimumKeys: Int
        /// 한글 모드 → 영어: 음절만 나왔을 때 한국어 점수가 이 값 이상이면 그대로 둔다. nil이면 점수를 보지 않는다.
        public var hangulReject: Double?
        /// 한글 모드 → 영어: 사전에 없어도 음절이 되지 못한 모음이 남으면 영어로 본다.
        public var looseVowelMeansLatin: Bool

        /// 기본값은 Tests/perf/mistype-eval.sh로 정했다(ADR 0041): 오탐 0.5/1000 이하에서 검출이 높은 설정 중
        /// 오탐이 더 낮은 쪽. 영문 모드 −2.75(추천 −3.0보다 검출 0.5%p 낮고 코드 오탐이 적다), 한글 모드는 추천 그대로.
        public init(latinMinimumKeys: Int = 3, hangulAccept: Double = -2.75,
                    hangulMinimumKeys: Int = 2, hangulReject: Double? = -2.5, looseVowelMeansLatin: Bool = true) {
            self.latinMinimumKeys = latinMinimumKeys
            self.hangulAccept = hangulAccept
            self.hangulMinimumKeys = hangulMinimumKeys
            self.hangulReject = hangulReject
            self.looseVowelMeansLatin = looseVowelMeansLatin
        }
    }

    public let lexicon: EnglishLexicon
    public let model: HangulSyllableModel
    public var thresholds: Thresholds
    /// 영어 접두사(ADR 0042). 있으면 치는 중에도 판정한다(`judgeEarly`).
    public let prefixes: EnglishPrefixIndex?
    public var earlyThresholds: EarlyThresholds

    public init(lexicon: EnglishLexicon, model: HangulSyllableModel, thresholds: Thresholds = Thresholds(),
                prefixes: EnglishPrefixIndex? = nil, earlyThresholds: EarlyThresholds = EarlyThresholds()) {
        self.lexicon = lexicon
        self.model = model
        self.thresholds = thresholds
        self.prefixes = prefixes
        self.earlyThresholds = earlyThresholds
    }

    /// 키 입력(QWERTY 글자, 대문자는 Shift)을 두 언어로 풀어 본다. 영문자가 아닌 키가 있으면 nil.
    public func features(keys: String) -> MistypeFeatures? {
        let hangul = Dubeolsik.compose(keys: keys)
        guard hangul.isValid else { return nil }
        return MistypeFeatures(
            keys: keys,
            latin: keys,
            latinIsWord: Self.hasEnglishCasing(keys) && lexicon.contains(keys),
            hasPlainShift: keys.contains(where: Dubeolsik.isPlainShift),
            hangul: hangul,
            hangulScore: hangul.isAllSyllables ? model.score(hangul.text) : nil
        )
    }

    public func judge(keys: String, typedIn mode: TypingMode) -> MistypeVerdict {
        guard let features = features(keys: keys) else { return .keep }
        return Self.judge(features, typedIn: mode, thresholds: thresholds)
    }

    public static func judge(_ f: MistypeFeatures, typedIn mode: TypingMode, thresholds t: Thresholds) -> MistypeVerdict {
        switch mode {
        case .latin:
            guard f.keys.count >= t.latinMinimumKeys, !f.latinIsWord, !f.hasPlainShift,
                  let score = f.hangulScore, score >= t.hangulAccept else { return .keep }
            return .meantHangul(f.hangul.text)
        case .hangul:
            guard f.keys.count >= t.hangulMinimumKeys, !isJamoExpression(f.hangul) else { return .keep }
            if f.latinIsWord {
                if !f.hasPlainShift, let reject = t.hangulReject, let score = f.hangulScore, score >= reject { return .keep }
                return .meantLatin(f.latin)
            }
            return t.looseVowelMeansLatin && f.hasLooseVowel ? .meantLatin(f.latin) : .keep
        }
    }

    /// 소문자, 첫 글자만 대문자, 모두 대문자 중 하나.
    static func hasEnglishCasing(_ word: String) -> Bool {
        let rest = word.dropFirst()
        return rest.allSatisfy(\.isLowercase) || word.allSatisfy(\.isUppercase)
    }

    /// 한글 모드에서 일부러 치는 낱자 표현.
    /// - 같은 낱자 반복(ㅋㅋㅋ, ㅠㅠ), 세 타 이하 초성체(ㅎㄷㄷ, ㅇㅋ)
    /// - 웃음·울음 표현: ㅋ ㅎ ㅠ ㅜ ㅡ 낱자와, 이들이 붙어 생긴 받침 없는 음절(큐, 후, 크 …)만으로 된 것(ㅜㅠ, ㅡㅜ, ㅠㅠㅋㅋ, ㅋ큐ㅠ)
    static func isJamoExpression(_ c: Dubeolsik.Composition) -> Bool {
        if c.syllableCount == 0 {
            if Set(c.looseJamo).count == 1 { return true }
            if c.looseJamo.count <= 3 && !c.looseJamo.contains(where: Dubeolsik.isVowel) { return true }
        }
        return !c.units.isEmpty && c.units.allSatisfy { unit in
            switch unit {
            case .loose(let jamo): return emoticonJamo.contains(jamo)
            case .syllable(let syllable): return emoticonSyllables.contains(syllable)
            }
        }
    }

    private static let emoticonJamo: Set<Character> = ["ㅋ", "ㅎ", "ㅠ", "ㅜ", "ㅡ"]
    /// ㅋ·ㅎ 뒤에 ㅠ·ㅜ·ㅡ가 와서 두벌식이 음절로 묶은 것(ㅋㅋㅠㅠ → ㅋ큐ㅠ)
    private static let emoticonSyllables: Set<Character> = ["큐", "쿠", "크", "휴", "후", "흐"]
}
