import Foundation

/// 한글 음절 bigram 모델(ADR 0040). 단어가 "한국어다운지"를 음절당 평균 로그 확률로 매긴다.
///
/// - 단어 앞뒤에 경계 기호를 붙여 첫 음절·끝 음절의 자연스러움도 본다.
/// - bigram과 unigram을 섞고(보간), unigram은 11,172개 음절 전체에 대해 더하기 평활화를 한다.
///   처음 보는 음절도 0이 아닌 확률을 받는다.
/// - 앞 음절로 쓰인 횟수(bigram 조건부 확률의 분모)는 unigram 횟수와 같다. 음절마다 뒤에 다음 음절이나 끝 경계가 오기 때문이다.
///   그래서 bigram을 줄여도(`pruned`) 분모는 그대로다.
public struct HangulSyllableModel: Sendable, Equatable {
    /// 단어 경계. 한글 음절과 겹치지 않는 문자.
    static let boundary: Character = "#"
    static let syllableCount = 11_172

    public var bigramWeight: Double
    public var unigramSmoothing: Double

    private var unigrams: [Character: Int] = [:]
    private var bigrams: [Bigram: Int] = [:]
    private var totalUnigrams = 0

    private struct Bigram: Hashable, Sendable {
        let first: Character
        let second: Character
    }

    public init(bigramWeight: Double = 0.7, unigramSmoothing: Double = 0.5) {
        self.bigramWeight = bigramWeight
        self.unigramSmoothing = unigramSmoothing
    }

    /// 학습한 단어 수가 아니라 음절 수(경계 포함)
    public var trainedTokens: Int { totalUnigrams }
    public var bigramCount: Int { bigrams.count }

    /// 한글 음절로만 된 단어 하나를 학습한다. 다른 글자가 섞여 있으면 무시하고 false.
    @discardableResult
    public mutating func train(word: String, count: Int = 1) -> Bool {
        guard !word.isEmpty, word.allSatisfy(Dubeolsik.isSyllable) else { return false }
        var previous = Self.boundary
        for syllable in word + String(Self.boundary) {
            unigrams[syllable, default: 0] += count
            totalUnigrams += count
            bigrams[Bigram(first: previous, second: syllable), default: 0] += count
            previous = syllable
        }
        return true
    }

    /// 드문 bigram을 버린 모델(앱에 넣을 크기로 줄인다). unigram은 그대로 둔다.
    public func pruned(minimumBigramCount: Int) -> HangulSyllableModel {
        var copy = self
        copy.bigrams = bigrams.filter { $0.value >= minimumBigramCount }
        return copy
    }

    /// 음절당 평균 log10 확률(끝 경계 포함). 한글 음절이 아닌 글자가 있으면 nil.
    /// 값이 클수록(0에 가까울수록) 한국어답다.
    /// - isPrefix: 치는 중인 단어의 앞부분이다. 끝 경계를 넣지 않는다(단어가 여기서 끝난다고 보지 않는다).
    public func score(_ word: String, isPrefix: Bool = false) -> Double? {
        guard !word.isEmpty, word.allSatisfy(Dubeolsik.isSyllable) else { return nil }
        var previous = Self.boundary
        var sum = 0.0
        var steps = 0
        for syllable in isPrefix ? word : word + String(Self.boundary) {
            sum += log10(probability(of: syllable, after: previous))
            steps += 1
            previous = syllable
        }
        return sum / Double(steps)
    }

    private func probability(of syllable: Character, after previous: Character) -> Double {
        let vocabulary = Double(Self.syllableCount + 1)
        let unigram = (Double(unigrams[syllable] ?? 0) + unigramSmoothing)
            / (Double(totalUnigrams) + unigramSmoothing * vocabulary)
        guard let context = unigrams[previous], context > 0 else { return unigram }
        let bigram = Double(bigrams[Bigram(first: previous, second: syllable)] ?? 0) / Double(context)
        return bigramWeight * bigram + (1 - bigramWeight) * unigram
    }

    // MARK: 저장

    /// 탭으로 나눈 텍스트. 첫 줄은 형식 표시, 그다음 unigram("가\t횟수"), bigram("가나\t횟수") 순서.
    /// 경계는 "#"이다. 줄 순서는 정렬해 두어 다시 만들어도 같은 파일이 된다.
    static let header = "# KeyHue hangul syllable model v1"

    public func serialized() -> String {
        var lines = [Self.header]
        lines += unigrams.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }
        lines += bigrams
            .map { (String([$0.key.first, $0.key.second]), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)\t\($0.1)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `serialized()`로 만든 텍스트를 읽는다. 형식이 맞지 않으면 nil.
    public init?(serialized text: String, bigramWeight: Double = 0.7, unigramSmoothing: Double = 0.5) {
        self.init(bigramWeight: bigramWeight, unigramSmoothing: unigramSmoothing)
        // CRLF(git autocrlf 등)도 받는다. "\r\n"은 Swift에서 한 Character라 "\n"으로 나누면 안 된다.
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard lines.next().map(String.init) == Self.header else { return nil }
        while let line = lines.next() {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let count = Int(fields[1]), count >= 0 else { return nil }
            let key = Array(fields[0])
            switch key.count {
            case 1:
                // 같은 줄이 두 번이면 합계가 어긋난다. 합이 넘치면(깨진 파일) 멈추지 않고 읽기를 포기한다.
                guard unigrams[key[0]] == nil else { return nil }
                let (sum, overflow) = totalUnigrams.addingReportingOverflow(count)
                guard !overflow else { return nil }
                unigrams[key[0]] = count
                totalUnigrams = sum
            case 2:
                let bigram = Bigram(first: key[0], second: key[1])
                guard bigrams[bigram] == nil else { return nil }
                bigrams[bigram] = count
            default:
                return nil
            }
        }
        guard totalUnigrams > 0 else { return nil }
    }
}
