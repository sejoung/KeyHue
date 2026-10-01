// 잘못된 언어로 친 단어 판정기(ADR 0040)의 오탐률과 검출률을 말뭉치로 잰다. Tests/perf/mistype-eval.sh가 사용한다.
//
//   mistype-eval (--model <모델.tsv> | --train <파일>...) --hangul <이름>=<파일>... --latin <이름>=<파일>...
//                [--prefix-words system|<단어 목록>]... [--prune <최소 bigram 횟수>] [--lexicon spell|<단어 목록 파일>] [--max-fp 0.5] [--examples 30] [--out <폴더>]
//
// 정답 텍스트에서 "잘못된 모드로 친 입력"을 만들 수 있으므로 사람이 직접 칠 필요가 없다.
// - 한글 말뭉치: 한글 음절 덩어리마다 두벌식 키 입력을 만든다.
//     한글 모드로 쳤다 → 그대로 둬야 한다(영어로 판정하면 오탐).
//     영문 모드로 쳤다 → 한글로 판정해야 한다(검출).
// - 영문 말뭉치(문장·코드·셸 명령): 영문자 덩어리가 곧 키 입력이다.
//     영문 모드로 쳤다 → 그대로 둬야 한다(한글로 판정하면 오탐).
//     한글 모드로 쳤다 → 영어로 판정해야 한다(검출).
// 판정은 공백(스페이스·엔터)에서 한다고 본다. 공백으로 나눈 단어의 앞뒤 문장 부호를 떼고,
// 남은 것이 영문자만(또는 한글 음절만)이면 한 단어로 센다. 숫자·문장 부호가 가운데 섞인 단어(didn't, self.tap, API를)는 판정하지 않는다.
// 같은 단어는 한 번만 판정하고 나온 횟수만큼 곱한다(말뭉치에 나온 빈도 그대로의 비율).
//
// 판정 방향마다 임계값이 다르므로 따로 훑는다.
// - 영문 모드 판정: latinMinimumKeys × hangulAccept
// - 한글 모드 판정: hangulMinimumKeys × hangulReject(없음 = 점수를 보지 않음)
// 오탐이 모든 음성 말뭉치에서 1,000단어당 --max-fp 이하이고 낱자 표현(ㅋㅋ 등)을 하나도 바꾸지 않는 설정 중
// 검출률(양성 말뭉치 평균)이 가장 높은 것을 추천한다.
import AppKit
import Foundation

/// 같은 키 입력은 사전·모델을 한 번만 거친다.
final class FeatureCache {
    let detector: MistypeDetector
    private var cache: [String: MistypeFeatures] = [:]
    init(detector: MistypeDetector) { self.detector = detector }
    func features(_ keys: String) -> MistypeFeatures? {
        if let hit = cache[keys] { return hit }
        guard let f = detector.features(keys: keys) else { return nil }
        cache[keys] = f
        return f
    }
}

/// 말뭉치 하나. 덩어리(키 입력) → 나온 횟수.
struct Corpus {
    let name: String
    var runs: [String: Int] = [:]
    var total: Int { runs.values.reduce(0, +) }
}

typealias Script = MistypeText.Script

/// Leipzig 문장 파일("id\t문장"), 단어 파일("id\t단어\t빈도"), Tatoeba("id\tkor\t문장"), 일반 텍스트를 받는다.
func lines(of path: String) throws -> [(text: Substring, weight: Int)] {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    return content.split(whereSeparator: \.isNewline).map { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if fields.count == 3, let weight = Int(fields[2]), Int(fields[0]) != nil {
            return (fields[1], weight)
        }
        return (fields.count > 1 && Int(fields[0]) != nil ? fields[fields.count - 1] : line, 1)
    }
}

func loadCorpus(name: String, path: String, script: Script) throws -> Corpus {
    var corpus = Corpus(name: name)
    for (text, weight) in try lines(of: path) {
        for word in MistypeText.words(in: text, script: script) {
            let keys = script == .hangul ? (Dubeolsik.keys(for: word) ?? "") : word
            if !keys.isEmpty { corpus.runs[keys, default: 0] += weight }
        }
    }
    return corpus
}

/// 한글 모드에서 흔히 치는 낱자 표현. 한글 모드로 쳤으니 그대로 둬야 한다.
let jamoExpressions = [
    "ㅋㅋ", "ㅋㅋㅋ", "ㅋㅋㅋㅋ", "ㅋㅋㅋㅋㅋ", "ㅎㅎ", "ㅎㅎㅎ", "ㅠㅠ", "ㅠㅠㅠ", "ㅜㅜ", "ㅜㅜㅜ", "ㅡㅡ",
    "ㅇㅇ", "ㄴㄴ", "ㅇㅋ", "ㅇㅋㅇㅋ", "ㄱㄱ", "ㄱㄱㄱ", "ㅅㄱ", "ㄱㅅ", "ㅈㅅ", "ㅊㅋ", "ㄷㄷ", "ㄷㄷㄷ",
    "ㅂㅂ", "ㅎㅇ", "ㄹㅇ", "ㅇㄷ", "ㅁㄹ", "ㅇㅈ", "ㄴㅇㄱ", "ㅈㅂㅈㅇ", "ㅃㅇ", "ㅂㄷㅂㄷ", "ㅎㄷㄷ", "ㅋㅋㅋㅋㅋㅋ",
    "ㄱㅊ", "ㅊㅊ", "ㅅㅂ", "ㅈㄹ", "ㅁㅊ", "ㄹㅈㄷ", "ㅇㅎ", "ㅇㄱㄹㅇ", "ㄴㄱ", "ㅂㄹ"
]

struct Options {
    var train: [String] = []
    var model: String?
    var prune = 1
    var hangul: [(String, String)] = []
    var latin: [(String, String)] = []
    var lexicon = "spell"
    var maxFalsePerThousand = 0.5
    var examples = 30
    var out: String?
    /// 있으면 치는 중 판정(ADR 0042)도 잰다: 영어 접두사를 볼 단어 목록.
    var prefixWords: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func named(_ value: String) -> (String, String) {
        let parts = value.split(separator: "=", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (URL(fileURLWithPath: value).lastPathComponent, value)
    }
    while let arg = args.popFirst() {
        guard let value = args.popFirst() else { fatalError("\(arg)에 값이 없습니다") }
        switch arg {
        case "--train": options.train.append(value)
        case "--model": options.model = value
        case "--prune": options.prune = Int(value)!
        case "--hangul": options.hangul.append(named(value))
        case "--latin": options.latin.append(named(value))
        case "--lexicon": options.lexicon = value
        case "--max-fp": options.maxFalsePerThousand = Double(value)!
        case "--examples": options.examples = Int(value)!
        case "--out": options.out = value
        case "--prefix-words": options.prefixWords.append(value)
        default: fatalError("알 수 없는 옵션 \(arg)")
        }
    }
    return options
}

/// 한 방향(정답 모드 → 잘못 친 모드)의 결과.
struct Rates {
    struct Count { let name: String; var hits = 0; var total = 0 }
    var negatives: [Count] = []
    var positives: [Count] = []
    /// 반드시 그대로 둬야 하는 표현 중 바꾼 것
    var mustKeepChanged: [String] = []

    var recall: Double {
        let rates = positives.map { $0.total == 0 ? 0 : Double($0.hits) / Double($0.total) }
        return rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count)
    }
    var worstFalsePerThousand: Double {
        negatives.map { $0.total == 0 ? 0 : Double($0.hits) * 1000 / Double($0.total) }.max() ?? 0
    }
}

/// - negatives: 맞게 친 입력. `mode`로 판정해 무언가를 고치면 오탐.
/// - positives: 잘못 친 입력. `mode`로 판정해 고쳐야 검출.
/// - mustKeep: 맞게 친 입력 중 하나라도 바꾸면 안 되는 것(낱자 표현).
func evaluate(mode: TypingMode, thresholds: MistypeDetector.Thresholds,
              negatives: [Corpus], positives: [Corpus], mustKeep: [String], cache: FeatureCache) -> Rates {
    func count(_ corpus: Corpus) -> Rates.Count {
        var result = Rates.Count(name: corpus.name)
        for (keys, n) in corpus.runs {
            result.total += n
            guard let f = cache.features(keys) else { continue }
            if MistypeDetector.judge(f, typedIn: mode, thresholds: thresholds) != .keep { result.hits += n }
        }
        return result
    }
    var rates = Rates()
    rates.negatives = negatives.map(count)
    rates.positives = positives.map(count)
    rates.mustKeepChanged = mustKeep.filter { keys in
        guard let f = cache.features(keys) else { return false }
        return MistypeDetector.judge(f, typedIn: mode, thresholds: thresholds) != .keep
    }.map { Dubeolsik.compose(keys: $0).text }
    return rates
}

func column(_ text: String) -> String { String(text.prefix(9)).padding(toLength: 9, withPad: " ", startingAt: 0) + " " }

/// 치는 중 판정을 키 하나씩 흉내 낸다. 접두사마다 특징값을 한 번만 계산한다.
final class EarlyEvaluator {
    let detector: MistypeDetector
    let prefixes: EnglishPrefixIndex
    let boundary: FeatureCache
    private var features: [String: EarlyMistypeFeatures] = [:]

    init(detector: MistypeDetector, prefixes: EnglishPrefixIndex, boundary: FeatureCache) {
        self.detector = detector
        self.prefixes = prefixes
        self.boundary = boundary
    }

    struct Result {
        var total = 0, early = 0, boundaryOnly = 0
        var triggerKeys = 0, remainingKeys = 0
        var earlyRate: Double { total == 0 ? 0 : Double(early) / Double(total) }
        var totalRate: Double { total == 0 ? 0 : Double(early + boundaryOnly) / Double(total) }
        var meanTriggerKey: Double { early == 0 ? 0 : Double(triggerKeys) / Double(early) }
        var meanRemainingKeys: Double { early == 0 ? 0 : Double(remainingKeys) / Double(early) }
    }

    /// 처음 알린 시점(몇 타째). 끝까지 치는 동안 알리지 않으면 nil.
    func firstTrigger(_ keys: String, mode: TypingMode, thresholds: MistypeDetector.EarlyThresholds) -> Int? {
        var prefix = ""
        for (index, key) in keys.enumerated() {
            prefix.append(key)
            let f: EarlyMistypeFeatures
            if let hit = features[prefix] { f = hit } else {
                guard let computed = detector.earlyFeatures(keys: prefix, prefixes: prefixes) else { return nil }
                features[prefix] = computed
                f = computed
            }
            if MistypeDetector.judgeEarly(f, typedIn: mode, thresholds: thresholds) != .keep { return index + 1 }
        }
        return nil
    }

    func measure(_ corpus: Corpus, mode: TypingMode, thresholds: MistypeDetector.EarlyThresholds) -> Result {
        var r = Result()
        for (keys, count) in corpus.runs {
            r.total += count
            if let k = firstTrigger(keys, mode: mode, thresholds: thresholds) {
                r.early += count
                r.triggerKeys += k * count
                r.remainingKeys += (keys.count - k) * count
            } else if let f = boundary.features(keys),
                      MistypeDetector.judge(f, typedIn: mode, thresholds: boundary.detector.thresholds) != .keep {
                r.boundaryOnly += count
            }
        }
        return r
    }
}

func percent(_ value: Double) -> String { String(format: "%5.1f%%", value * 100) }
func perThousand(_ falses: Int, _ total: Int) -> String {
    String(format: "%6.2f", total == 0 ? 0 : Double(falses) * 1000 / Double(total))
}

@main
struct MistypeEval {
    static func main() throws {
        let options = parseOptions()
        var output = ""
        func say(_ line: String = "") {
            print(line)
            output += line + "\n"
        }

        // 1. 모델: 앱에 넣는 파일(scripts/build-mistype-model.sh)을 그대로 쓰거나, 말뭉치로 새로 학습한다.
        var model = HangulSyllableModel()
        if let path = options.model {
            guard let loaded = HangulSyllableModel(serialized: try String(contentsOfFile: path, encoding: .utf8)) else {
                fatalError("모델 파일 형식이 맞지 않습니다: \(path)")
            }
            model = loaded
        }
        for path in options.train {
            for (text, weight) in try lines(of: path) {
                for word in MistypeText.words(in: text, script: .hangul) { model.train(word: word, count: weight) }
            }
        }
        if options.prune > 1 { model = model.pruned(minimumBigramCount: options.prune) }
        let lexicon: EnglishLexicon
        if options.lexicon == "spell" {
            lexicon = SystemEnglishLexicon()
        } else {
            let words = try String(contentsOfFile: options.lexicon, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            lexicon = WordListLexicon(words)
        }
        let cache = FeatureCache(detector: MistypeDetector(lexicon: lexicon, model: model))

        // 2. 말뭉치
        let hangulCorpora = try options.hangul.map { try loadCorpus(name: $0.0, path: $0.1, script: .hangul) }
        let latinCorpora = try options.latin.map { try loadCorpus(name: $0.0, path: $0.1, script: .latin) }
        let jamoKeys = jamoExpressions.map { Dubeolsik.keys(for: $0)! }

        say("# 오타 언어 판정 측정 (ADR 0040)")
        say()
        let modelSource = options.model.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "\(options.train.map { URL(fileURLWithPath: $0).lastPathComponent })"
        say("- 모델: \(modelSource), 음절 \(model.trainedTokens)개(경계 포함), bigram \(model.bigramCount)개")
        say("- 영어 사전: \(options.lexicon == "spell" ? "NSSpellChecker(en)" : options.lexicon)")
        for corpus in hangulCorpora { say("- 한글 \(corpus.name): 단어 \(corpus.total)개 (서로 다른 것 \(corpus.runs.count)개)") }
        for corpus in latinCorpora { say("- 영문 \(corpus.name): 단어 \(corpus.total)개 (서로 다른 것 \(corpus.runs.count)개)") }
        say("- 낱자 표현(반드시 그대로): \(jamoExpressions.count)개")
        say("- 검출: 잘못된 모드로 친 단어 중 잡아낸 비율(짧아서 판정하지 않은 것 포함). 오탐: 맞게 친 1,000단어당 잘못 판정한 횟수")

        struct Row { let thresholds: MistypeDetector.Thresholds; let rates: Rates }


        func sweep(title: String, mode: TypingMode, settings: [(String, MistypeDetector.Thresholds)],
                   negatives: [Corpus], positives: [Corpus], mustKeep: [String]) -> Row? {
            say()
            say("## \(title)")
            say()
            let recallHeader = positives.map { column("검출 " + $0.name) }.joined(separator: " ")
            let falseHeader = negatives.map { column("오탐 " + $0.name) }.joined(separator: " ")
            say("설정                  \(recallHeader) \(falseHeader) 낱자")
            var best: Row?
            for (label, t) in settings {
                let rates = evaluate(mode: mode, thresholds: t, negatives: negatives, positives: positives, mustKeep: mustKeep, cache: cache)
                let recalls = rates.positives.map { column(percent($0.total == 0 ? 0 : Double($0.hits) / Double($0.total))) }.joined(separator: " ")
                let falses = rates.negatives.map { column(perThousand($0.hits, $0.total)) }.joined(separator: " ")
                say(label.padding(toLength: 22, withPad: " ", startingAt: 0) + "\(recalls) \(falses) \(rates.mustKeepChanged.joined(separator: ","))")
                if rates.worstFalsePerThousand <= options.maxFalsePerThousand, rates.mustKeepChanged.isEmpty,
                   rates.recall > (best?.rates.recall ?? -1) {
                    best = Row(thresholds: t, rates: rates)
                }
            }
            say()
            if let best, let label = settings.first(where: { $0.1 == best.thresholds })?.0 {
                say(String(format: "추천: %@ → 검출(평균) %@, 최악 오탐 %.2f/1000", label.trimmingCharacters(in: .whitespaces),
                           percent(best.rates.recall), best.rates.worstFalsePerThousand))
            } else {
                say("추천: 오탐 \(options.maxFalsePerThousand)/1000 이하인 설정이 없다")
            }
            return best
        }

        let latinSettings = [2, 3, 4, 5].flatMap { minimumKeys in
            stride(from: -2.0, through: -4.0, by: -0.25).map { accept in
                (String(format: "min %d acc %.2f", minimumKeys, accept),
                 MistypeDetector.Thresholds(latinMinimumKeys: minimumKeys, hangulAccept: accept))
            }
        }
        let hangulSettings = [false, true].flatMap { looseVowel in
            [2, 3, 4, 5].flatMap { minimumKeys in
                ([nil] + stride(from: -2.0, through: -3.0, by: -0.5).map { Optional($0) }).map { reject in
                    (String(format: "min %d rej %@%@", minimumKeys, reject.map { String(format: "%.1f", $0) } ?? "없음",
                            looseVowel ? " +모음" : ""),
                     MistypeDetector.Thresholds(hangulMinimumKeys: minimumKeys, hangulReject: reject, looseVowelMeansLatin: looseVowel))
                }
            }
        }

        let latinBest = sweep(title: "영문 모드로 친 것 → 한글 의도인가", mode: .latin, settings: latinSettings,
                              negatives: latinCorpora, positives: hangulCorpora, mustKeep: [])
        let hangulBest = sweep(title: "한글 모드로 친 것 → 영어 의도인가", mode: .hangul, settings: hangulSettings,
                               negatives: hangulCorpora, positives: latinCorpora, mustKeep: jamoKeys)

        // 3. 추천 설정에서 오탐·놓침 예시(빈도순)
        func examples(_ title: String, mode: TypingMode, thresholds: MistypeDetector.Thresholds, corpora: [Corpus], wantChange: Bool) {
            say()
            say("### \(title)")
            for corpus in corpora {
                let hits = corpus.runs.compactMap { keys, count -> (String, Int, MistypeFeatures)? in
                    let minimumKeys = mode == .latin ? thresholds.latinMinimumKeys : thresholds.hangulMinimumKeys
                    guard let f = cache.features(keys), keys.count >= minimumKeys else { return nil }
                    let changed = MistypeDetector.judge(f, typedIn: mode, thresholds: thresholds) != .keep
                    return changed == wantChange ? (keys, count, f) : nil
                }.sorted { $0.1 > $1.1 }.prefix(options.examples)
                guard !hits.isEmpty else { continue }
                say("- \(corpus.name): " + hits.map { keys, count, f in
                    let score = f.hangulScore.map { String(format: "%.2f", $0) } ?? "-"
                    return "\(keys)→\(f.hangul.text)(\(score))×\(count)"
                }.joined(separator: ", "))
            }
        }
        say()
        say("## 예시 (추천 설정, 빈도순, 형식: 키→두벌식(한국어 점수)×횟수)")
        if let latinBest {
            examples("영문 모드 오탐: 맞게 친 영문을 한글로 판정", mode: .latin, thresholds: latinBest.thresholds, corpora: latinCorpora, wantChange: true)
            examples("영문 모드 놓침: 영문 모드로 친 한글을 못 잡음(최소 길이 이상)", mode: .latin, thresholds: latinBest.thresholds,
                     corpora: hangulCorpora, wantChange: false)
        }
        if let hangulBest {
            examples("한글 모드 오탐: 맞게 친 한글을 영어로 판정", mode: .hangul, thresholds: hangulBest.thresholds, corpora: hangulCorpora, wantChange: true)
            examples("한글 모드 놓침: 한글 모드로 친 영문을 못 잡음(최소 길이 이상)", mode: .hangul, thresholds: hangulBest.thresholds,
                     corpora: latinCorpora, wantChange: false)
        }

        // 4. 치는 중 판정(ADR 0042): 키를 하나씩 치며 처음 알리는 시점을 잰다. 못 잡은 단어는 단어 끝 판정(기본값)으로 넘어간다.
        if !options.prefixWords.isEmpty {
            // "system"은 앱과 같은 출처(시스템 단어 목록 + 설치된 명령어 이름, EnglishPrefixIndex.loadWords)
            var words: [String] = []
            for path in options.prefixWords {
                words += path == "system"
                    ? EnglishPrefixIndex.loadWords(wordLists: EnglishPrefixIndex.systemWordLists,
                                                   commandDirectories: EnglishPrefixIndex.commandDirectories)
                    : try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
            }
            let early = EarlyEvaluator(detector: cache.detector, prefixes: EnglishPrefixIndex(words), boundary: cache)
            say()
            say("## 치는 중 판정 (ADR 0042)")
            say()
            say("- 영어 접두사: \(options.prefixWords.map { URL(fileURLWithPath: $0).lastPathComponent }), 단어 \(early.prefixes.count)개")
            say("- 치는 중: 공백을 누르기 전에 알린 비율. 합계: 치는 중 + 단어 끝 판정(기본값). 몇 타째: 치는 중에 알린 단어의 평균, 남은 타: 그 뒤로 더 쳤을 타 수 평균")
            say("- 오탐: 맞게 친 1,000단어당 치는 중 / 합계")
            for (mode, positives, negatives) in [(TypingMode.latin, hangulCorpora, latinCorpora), (.hangul, latinCorpora, hangulCorpora)] {
                say()
                say(mode == .latin ? "### 영문 모드로 친 한글" : "### 한글 모드로 친 영어")
                say()
                let settings: [MistypeDetector.EarlyThresholds] = mode == .latin
                    ? [2, 3, 4].flatMap { k in stride(from: -2.0, through: -3.0, by: -0.25).map { .init(latinMinimumKeys: k, hangulAccept: $0) } }
                    : [2, 3].map { .init(hangulMinimumKeys: $0, hangulConsonantRun: nil) } // 낱자 모음만(0042 처음)
                        + [2, 3, 4].map { .init(hangulMinimumKeys: 2, hangulConsonantRun: $0) }
                        + [-3.5, -4.0, -4.5].map { .init(hangulMinimumKeys: 2, hangulRejectStable: $0) }
                        + [-4.0].map { .init(hangulMinimumKeys: 2, hangulConsonantRun: 3, hangulRejectStable: $0) }
                let header = positives.map { column("치는중 " + $0.name) + column("합계") + column("몇 타째") + column("남은 타") }.joined()
                    + negatives.map { column("오탐 " + $0.name) + column("합계") }.joined()
                say("설정                  " + header + "낱자")
                for t in settings {
                    let label = mode == .latin ? String(format: "min %d acc %.2f", t.latinMinimumKeys, t.hangulAccept)
                        : String(format: "min %d", t.hangulMinimumKeys)
                            + (t.hangulConsonantRun.map { " 자음\($0)" } ?? "")
                            + (t.hangulRejectStable.map { String(format: " rej%.1f", $0) } ?? "")
                    var row = label.padding(toLength: 22, withPad: " ", startingAt: 0)
                    for corpus in positives {
                        let r = early.measure(corpus, mode: mode, thresholds: t)
                        row += column(percent(r.earlyRate)) + column(percent(r.totalRate))
                            + column(String(format: "%.1f", r.meanTriggerKey)) + column(String(format: "%.1f", r.meanRemainingKeys))
                    }
                    for corpus in negatives {
                        let r = early.measure(corpus, mode: mode, thresholds: t)
                        row += column(perThousand(r.early, r.total)) + column(perThousand(r.early + r.boundaryOnly, r.total))
                    }
                    if mode == .hangul {
                        row += jamoKeys.filter { early.firstTrigger($0, mode: mode, thresholds: t) != nil }
                            .map { Dubeolsik.compose(keys: $0).text }.joined(separator: ",")
                    }
                    say(row)
                }
                // 기본값에서 치는 중 오탐 예시
                let t = MistypeDetector.EarlyThresholds()
                say()
                say("기본값(\(mode == .latin ? "min \(t.latinMinimumKeys) acc \(t.hangulAccept)" : "min \(t.hangulMinimumKeys)")) 치는 중 오탐 예시(단어 → 알린 시점의 앞부분):")
                for corpus in negatives {
                    let hits = corpus.runs.compactMap { keys, count -> (String, Int, String)? in
                        guard let k = early.firstTrigger(keys, mode: mode, thresholds: t) else { return nil }
                        return (keys, count, String(keys.prefix(k)))
                    }.sorted { $0.1 > $1.1 }.prefix(options.examples)
                    say("- \(corpus.name): " + hits.map { "\($0.0)→\($0.2)(\(Dubeolsik.compose(keys: $0.2).text))×\($0.1)" }.joined(separator: ", "))
                }
            }
        }

        if let out = options.out {
            try output.write(toFile: (out as NSString).appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
    }
}
