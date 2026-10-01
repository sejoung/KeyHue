import Foundation

/// 두벌식 배열과 한글 조합(ADR 0040, 실험적 오타 언어 판정 0단계).
///
/// 키 입력은 **QWERTY 글자**로 나타낸다. macOS 키 코드는 배열과 상관없이 같으므로,
/// 같은 키 입력을 영문(그대로)과 두벌식 한글(이 타입)로 동시에 풀 수 있다.
/// 대문자는 Shift를 누른 키다(두벌식에서 Shift+Q=ㅃ, Shift+O=ㅒ 등).
public enum Dubeolsik {
    // MARK: 배열

    private static let lower: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ"
    ]
    /// Shift로 다른 자모가 나오는 키. 나머지 대문자는 소문자와 같은 자모다.
    private static let shifted: [Character: Character] = [
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ"
    ]
    private static let keyForJamo: [Character: String] = {
        var map: [Character: String] = [:]
        for (key, jamo) in lower { map[jamo] = String(key) }
        for (key, jamo) in shifted { map[jamo] = String(key) }
        return map
    }()

    /// 키 하나가 두벌식에서 내는 자모. 영문자가 아니면 nil.
    public static func jamo(forKey key: Character) -> Character? {
        if let jamo = shifted[key] { return jamo }
        guard let lowered = key.lowercased().first else { return nil }
        return lower[lowered]
    }

    /// 두벌식에서 Shift가 아무 의미 없는 대문자(Q W E R T O P 외). 한글을 칠 때는 누를 일이 없으므로 영어를 치려던 신호다.
    public static func isPlainShift(_ key: Character) -> Bool {
        key.isUppercase && shifted[key] == nil
    }

    // MARK: 조합 표(호환용 자모)

    private static let choseong = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let jungseong = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// 0번은 받침 없음.
    private static let jongseong: [Character?] = [nil] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map { $0 }

    private static let compoundVowels: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"
    ]
    private static let compoundFinals: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ"
    ]
    private static let splitVowels: [Character: String] = Dictionary(uniqueKeysWithValues: compoundVowels.map { ($1, $0) })
    private static let splitFinals: [Character: String] = Dictionary(uniqueKeysWithValues: compoundFinals.map { ($1, $0) })

    static func isVowel(_ jamo: Character) -> Bool { jungseong.contains(jamo) }

    // MARK: 조합

    /// 키 입력을 두벌식으로 조합한 결과. 음절을 이루지 못한 자모는 낱자로 남는다(예: "ㅗ디ㅣㅐ").
    public struct Composition: Equatable, Sendable {
        public let text: String
        /// 완성된 음절 수
        public let syllableCount: Int
        /// 음절을 이루지 못한 낱자 수
        public let looseJamoCount: Int
        /// 음절을 이루지 못한 낱자들(순서대로). ㅋㅋ·ㅠㅠ 같은 표현을 가려낼 때 쓴다.
        public let looseJamo: [Character]
        /// 조합된 글자 단위(음절 또는 낱자) 순서대로.
        public let units: [Unit]

        /// 영문자가 아닌 키가 있었거나 비어 있으면 false.
        public let isValid: Bool

        public var isAllSyllables: Bool { isValid && looseJamoCount == 0 && syllableCount > 0 }

        /// 치는 중일 때 확정된 글자들: 마지막 글자를 뺀 앞부분.
        /// 마지막 글자는 다음 키에 따라 바뀔 수 있다(받침이 다음 음절로 넘어가거나, ㅗ가 ㅘ가 되거나, 자음이 초성이 된다).
        public var committedUnits: ArraySlice<Unit> { units.dropLast() }
    }

    public enum Unit: Equatable, Sendable {
        case syllable(Character)
        case loose(Character)

        public var isLooseVowel: Bool {
            if case .loose(let jamo) = self { return Dubeolsik.isVowel(jamo) }
            return false
        }
    }

    /// macOS 두벌식과 같은 규칙으로 조합한다.
    /// - 받침 뒤에 모음이 오면 받침이 다음 음절의 초성으로 넘어간다(겹받침은 뒤 자음만).
    /// - 겹모음(ㅘ 등)과 겹받침(ㄳ 등)을 만든다. 쌍자음(ㄲ 등)은 Shift로만 나온다.
    public static func compose(keys: String) -> Composition {
        var builder = Builder()
        for key in keys {
            guard let jamo = jamo(forKey: key) else {
                return Composition(text: "", syllableCount: 0, looseJamoCount: 0, looseJamo: [], units: [], isValid: false)
            }
            builder.input(jamo)
        }
        builder.flush()
        return Composition(
            text: builder.text,
            syllableCount: builder.syllables,
            looseJamoCount: builder.loose.count,
            looseJamo: builder.loose,
            units: builder.units,
            isValid: !keys.isEmpty
        )
    }

    private struct Builder {
        var cho: Character?
        var jung: Character?
        var jong: Character?
        var text = ""
        var syllables = 0
        var loose: [Character] = []
        var units: [Unit] = []

        mutating func input(_ jamo: Character) {
            if isVowel(jamo) { vowel(jamo) } else { consonant(jamo) }
        }

        private mutating func consonant(_ c: Character) {
            if cho != nil, jung != nil {
                if let jong {
                    if let compound = compoundFinals["\(jong)\(c)"] {
                        self.jong = compound
                        return
                    }
                } else if jongseong.contains(c) {
                    jong = c
                    return
                }
            }
            flush()
            cho = c
        }

        private mutating func vowel(_ v: Character) {
            if let jung, jong == nil, let compound = compoundVowels["\(jung)\(v)"] {
                self.jung = compound
                return
            }
            if cho != nil, jung == nil {
                jung = v
                return
            }
            if cho != nil, jung != nil, let jong {
                // 도깨비불: 받침(겹받침이면 뒤 자음)이 새 음절의 초성이 된다.
                let moved: Character
                if let parts = splitFinals[jong] {
                    self.jong = parts.first
                    moved = parts.last!
                } else {
                    self.jong = nil
                    moved = jong
                }
                flush()
                cho = moved
                jung = v
                return
            }
            flush()
            jung = v
        }

        mutating func flush() {
            switch (cho, jung) {
            case let (c?, v?):
                let l = choseong.firstIndex(of: c)!
                let m = jungseong.firstIndex(of: v)!
                let t = jongseong.firstIndex(of: jong) ?? 0
                let syllable = Character(UnicodeScalar(0xAC00 + (l * 21 + m) * 28 + t)!)
                text.append(syllable)
                units.append(.syllable(syllable))
                syllables += 1
            case let (c?, nil):
                text.append(c)
                loose.append(c)
                units.append(.loose(c))
            case let (nil, v?):
                text.append(v)
                loose.append(v)
                units.append(.loose(v))
            case (nil, nil):
                break
            }
            cho = nil
            jung = nil
            jong = nil
        }
    }

    // MARK: 한글 → 키 (측정용)

    /// 한글 음절과 호환용 자모를 두벌식 키 입력으로 바꾼다. 그 밖의 글자가 있으면 nil.
    public static func keys(for hangul: String) -> String? {
        var result = ""
        for scalar in hangul.unicodeScalars {
            let value = Int(scalar.value)
            if (0xAC00...0xD7A3).contains(value) {
                let index = value - 0xAC00
                let parts: [Character?] = [choseong[index / 588], jungseong[(index % 588) / 28], jongseong[index % 28]]
                for case let jamo? in parts {
                    result += keys(forJamo: jamo)
                }
            } else {
                let jamoKeys = keys(forJamo: Character(String(scalar)))
                guard !jamoKeys.isEmpty else { return nil }
                result += jamoKeys
            }
        }
        return result
    }

    private static func keys(forJamo jamo: Character) -> String {
        if let key = keyForJamo[jamo] { return key }
        if let parts = splitVowels[jamo] ?? splitFinals[jamo] {
            return parts.map { keyForJamo[$0]! }.joined()
        }
        return ""
    }

    /// 완성형 한글 음절인가.
    public static func isSyllable(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
        return (0xAC00...0xD7A3).contains(Int(scalar.value))
    }
}

/// 말뭉치에서 판정 단위(단어)를 뽑는다. 모델 학습(scripts/build-mistype-model.sh)과 측정(Tests/perf/mistype-eval.sh)이 같은 규칙을 쓴다.
public enum MistypeText {
    public enum Script: Sendable { case hangul, latin }

    /// 공백으로 나눠 앞뒤 문장 부호를 떼고, 한 문자 체계로만 된 단어를 뽑는다.
    /// 판정은 공백에서 하므로 가운데에 숫자·문장 부호가 섞인 단어(didn't, API를)는 단어로 치지 않는다.
    public static func words(in line: Substring, script: Script) -> [String] {
        line.split(whereSeparator: \.isWhitespace).compactMap { token in
            let word = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !word.isEmpty else { return nil }
            switch script {
            case .hangul: return word.allSatisfy(Dubeolsik.isSyllable) ? word : nil
            case .latin: return word.allSatisfy { $0.isASCII && $0.isLetter } ? word : nil
            }
        }
    }
}
