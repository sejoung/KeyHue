import AppKit
// Tests/perf/mistype-eval.sh는 이 파일을 Core 판정기 파일과 한 모듈로 컴파일한다(그때는 KeyHueCore 모듈이 없다).
#if canImport(KeyHueCore)
import KeyHueCore
#endif

/// macOS 시스템 사전(NSSpellChecker, 영어)으로 영어 단어인지 본다(ADR 0041). 사용자가 사전에 배운 단어도 포함된다.
///
/// NSSpellChecker는 로마 숫자 글자(i v x l c d m)로만 된 문자열을 모두 맞다고 한다(vlxl = 피티, dmdm = 으으).
/// 그런 문자열은 시스템 단어 목록(/usr/share/dict/words)에도 있어야 단어로 본다.
struct SystemEnglishLexicon: EnglishLexicon {
    private let romanNumeralWords: Set<String>

    init(wordListPath: String = "/usr/share/dict/words") {
        let words = (try? String(contentsOfFile: wordListPath, encoding: .utf8)) ?? ""
        romanNumeralWords = Set(
            words.split(whereSeparator: \.isNewline).map { $0.lowercased() }.filter(Self.isRomanNumeralLetters)
        )
    }

    static func isRomanNumeralLetters(_ word: String) -> Bool {
        word.lowercased().allSatisfy { "ivxlcdm".contains($0) }
    }

    func contains(_ word: String) -> Bool {
        if Self.isRomanNumeralLetters(word), !romanNumeralWords.contains(word.lowercased()) { return false }
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }
}
