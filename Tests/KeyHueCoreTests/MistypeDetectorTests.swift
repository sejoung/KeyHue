import Foundation
import Testing
@testable import KeyHueCore

@Suite("Dubeolsik composition")
struct DubeolsikTests {
    @Test(arguments: [
        ("dkssud", "안녕"),
        ("gksrmf", "한글"),
        ("rhkswls", "관진"),
        ("dlrtnr", "익숙"),       // ㄱ+ㅅ이 겹받침이 됐다가 모음이 오면 다시 나뉜다
        ("ekfrdl", "닭이"),       // 겹받침 ㄺ 뒤 모음: ㄱ만 넘어간다
        ("Rkcl", "까치"),         // Shift+R = ㄲ
        ("dmlwk", "의자"),        // 겹모음 ㅢ
        ("dhksfy", "완료"),
        ("Tkdh", "싸오")
    ])
    func composesLikeMacOS(keys: String, expected: String) {
        let c = Dubeolsik.compose(keys: keys)
        #expect(c.text == expected)
        #expect(c.isAllSyllables)
    }

    // macOS 두벌식에서 확인(2026-10-03): 모음 없이 친 ㅂ+ㅅ은 ㅄ으로 합치지 않고 ㅂㅅ으로 남는다.
    // 겹받침은 모음이 있는 음절 뒤에서만 만든다. 다른 겹받침 쌍도 같다.
    @Test(arguments: [
        ("qt", "ㅂㅅ"), ("rt", "ㄱㅅ"), ("sw", "ㄴㅈ"), ("sg", "ㄴㅎ"), ("fr", "ㄹㄱ"),
        ("fa", "ㄹㅁ"), ("fq", "ㄹㅂ"), ("ft", "ㄹㅅ"), ("fx", "ㄹㅌ"), ("fv", "ㄹㅍ"), ("fg", "ㄹㅎ")
    ])
    func consonantPairsWithoutAVowelStaySeparate(keys: String, expected: String) {
        let c = Dubeolsik.compose(keys: keys)
        #expect(c.text == expected)
        #expect(c.syllableCount == 0)
        #expect(c.looseJamoCount == 2)
    }

    @Test func vowelAfterASeparateConsonantPairJoinsOnlyTheSecond() {
        #expect(Dubeolsik.compose(keys: "qtk").text == "ㅂ사")
        // With a vowel first, the same keys do form the compound final.
        #expect(Dubeolsik.compose(keys: "rkqt").text == "값")
    }

    @Test func leavesLooseJamoWhenKeysDoNotFormSyllables() {
        let c = Dubeolsik.compose(keys: "hello")
        #expect(c.text == "ㅗ디ㅣㅐ")
        #expect(c.syllableCount == 1)
        #expect(c.looseJamoCount == 3)
        #expect(!c.isAllSyllables)
    }

    @Test func rejectsNonLetterKeys() {
        #expect(!Dubeolsik.compose(keys: "ab1").isValid)
        #expect(!Dubeolsik.compose(keys: "").isValid)
    }

    @Test func everySyllableRoundTrips() {
        for value in 0xAC00...0xD7A3 {
            let syllable = String(Character(UnicodeScalar(value)!))
            let keys = Dubeolsik.keys(for: syllable)
            #expect(keys.map { Dubeolsik.compose(keys: $0).text } == syllable, "\(syllable)")
        }
    }

    @Test func wordsRoundTrip() {
        for word in ["안녕하세요", "입력기", "꽃잎이", "읽었다", "괜찮아요", "없어서", "앉아", "ㅋㅋㅋ", "ㅠㅠ"] {
            let keys = Dubeolsik.keys(for: word)
            #expect(keys.map { Dubeolsik.compose(keys: $0).text } == word, "\(word)")
        }
    }

    @Test func keysForNonHangulIsNil() {
        #expect(Dubeolsik.keys(for: "abc") == nil)
        #expect(Dubeolsik.keys(for: "한a") == nil)
    }
}

@Suite("Hangul syllable model")
struct HangulSyllableModelTests {
    @Test func commonWordsScoreHigherThanUnseenOnes() {
        var model = HangulSyllableModel()
        for word in ["안녕", "안녕하세요", "하세요", "한글", "입력", "입력기"] {
            model.train(word: word, count: 10)
        }
        let seen = model.score("안녕하세요")!
        let unseen = model.score("솓뷁")!
        #expect(seen > unseen)
    }

    @Test func serializationRoundTrips() {
        var model = HangulSyllableModel()
        for word in ["안녕", "안녕하세요", "한글"] { model.train(word: word, count: 3) }
        let text = model.serialized()
        #expect(text.hasPrefix("# KeyHue hangul syllable model v1\n"))
        let loaded = HangulSyllableModel(serialized: text)
        #expect(loaded == model)
        #expect(loaded?.score("안녕") == model.score("안녕"))
        // 다시 저장해도 같은 파일(줄 순서 고정)
        #expect(loaded?.serialized() == text)
    }

    @Test func rejectsMalformedModelText() {
        #expect(HangulSyllableModel(serialized: "") == nil)
        #expect(HangulSyllableModel(serialized: "가\t1\n") == nil)                     // 머리줄 없음
        #expect(HangulSyllableModel(serialized: "# KeyHue hangul syllable model v1\n가\tx\n") == nil)
        #expect(HangulSyllableModel(serialized: "# KeyHue hangul syllable model v1\n") == nil) // 비어 있음
    }

    @Test func pruningKeepsUnigramsAndDropsRareBigrams() {
        var model = HangulSyllableModel()
        model.train(word: "안녕", count: 5)
        model.train(word: "녕안", count: 1)
        let pruned = model.pruned(minimumBigramCount: 2)
        #expect(pruned.bigramCount < model.bigramCount)
        #expect(pruned.trainedTokens == model.trainedTokens)
        #expect(pruned.score("안녕")! > pruned.score("녕안")!)
    }

    @Test func ignoresNonSyllables() {
        var model = HangulSyllableModel()
        let trainedLatin = model.train(word: "abc")
        let trainedJamo = model.train(word: "ㅋㅋ")
        #expect(!trainedLatin)
        #expect(!trainedJamo)
        #expect(model.score("ㅋㅋ") == nil)
        #expect(model.trainedTokens == 0)
    }
}

@Suite("Mistype detector")
struct MistypeDetectorTests {
    static let model: HangulSyllableModel = {
        var model = HangulSyllableModel()
        for word in ["안녕", "안녕하세요", "한글", "입력", "입력기", "오늘", "날씨", "좋다", "하세요", "합니다", "있습니다"] {
            model.train(word: word, count: 20)
        }
        return model
    }()
    static let lexicon = WordListLexicon(["hello", "the", "world", "test", "zzz", "and", "input", "you", "when"])
    let detector = MistypeDetector(lexicon: lexicon, model: model)

    @Test func koreanTypedInLatinModeIsDetected() {
        #expect(detector.judge(keys: "dkssudgktpdy", typedIn: .latin) == .meantHangul("안녕하세요"))
        #expect(detector.judge(keys: "dlqfurrl", typedIn: .latin) == .meantHangul("입력기"))
    }

    @Test func plainShiftMeansLatin() {
        // 두벌식에서 Shift+D는 ㅇ과 같으므로 한글을 칠 때 누르지 않는다: 고유명사 등 영어로 본다
        #expect(detector.judge(keys: "Dkssud", typedIn: .latin) == .keep)
        // Shift+R(ㄲ)처럼 의미 있는 Shift는 한글일 수 있다
        #expect(!Dubeolsik.isPlainShift("R"))
        #expect(Dubeolsik.isPlainShift("D"))
        #expect(!Dubeolsik.isPlainShift("d"))
    }

    @Test func englishWordsTypedInLatinModeAreKept() {
        #expect(detector.judge(keys: "hello", typedIn: .latin) == .keep)
        #expect(detector.judge(keys: "world", typedIn: .latin) == .keep)
    }

    @Test func latinNonWordsThatAreNotKoreanAreKept() {
        // 사전에 없는 식별자라도 두벌식으로 음절이 안 되면 그대로 둔다
        #expect(detector.judge(keys: "kubectl", typedIn: .latin) == .keep)
        #expect(detector.judge(keys: "xcrun", typedIn: .latin) == .keep)
    }

    @Test func englishTypedInHangulModeIsDetected() {
        #expect(detector.judge(keys: "hello", typedIn: .hangul) == .meantLatin("hello"))
        #expect(detector.judge(keys: "test", typedIn: .hangul) == .meantLatin("test"))
        // 음절이 되더라도(조두) 기본은 점수를 보지 않는다
        #expect(detector.judge(keys: "when", typedIn: .hangul) == .meantLatin("when"))
    }

    @Test func optionalRejectScoreKeepsKoreanLookingSyllables() {
        var detector = detector
        detector.thresholds.hangulReject = -10
        #expect(detector.judge(keys: "when", typedIn: .hangul) == .keep)
        #expect(detector.judge(keys: "hello", typedIn: .hangul) == .meantLatin("hello")) // 낱자가 남으면 점수 없음
    }

    @Test func koreanTypedInHangulModeIsKept() {
        #expect(detector.judge(keys: "dkssud", typedIn: .hangul) == .keep)
    }

    @Test func repeatedJamoExpressionsAreKept() {
        // ㅋㅋㅋ = zzz가 사전에 있어도 한국어 표현으로 본다
        #expect(detector.judge(keys: "zzzz", typedIn: .hangul) == .keep)
        // ㅎㄷㄷ = gee: 세 타 이하 초성체는 영어 단어여도 그대로
        let detector = MistypeDetector(lexicon: WordListLexicon(["gee", "test"]), model: Self.model,
                                       thresholds: .init(hangulMinimumKeys: 3))
        #expect(detector.judge(keys: "gee", typedIn: .hangul) == .keep)
        #expect(detector.judge(keys: "test", typedIn: .hangul) == .meantLatin("test")) // ㅅㄷㄴㅅ: 네 타부터는 판정
    }

    @Test func shortInputIsNotJudged() {
        #expect(detector.judge(keys: "dk", typedIn: .latin) == .keep)   // 아
        var detector = detector
        detector.thresholds.hangulMinimumKeys = 4
        #expect(detector.judge(keys: "you", typedIn: .hangul) == .keep) // ㅛㅐㅕ
        detector.thresholds.hangulMinimumKeys = 3
        #expect(detector.judge(keys: "you", typedIn: .hangul) == .meantLatin("you"))
    }

    @Test func innerCapitalsAreNotEnglish() {
        // wkRn(자꾸): 가운데 대문자는 두벌식 쌍자음이다. 사전이 받아 줘도 영어로 보지 않는다
        let detector = MistypeDetector(lexicon: WordListLexicon(["wkrn", "hello"]), model: Self.model)
        #expect(detector.judge(keys: "wkRn", typedIn: .hangul) == .keep)
        #expect(MistypeDetector.hasEnglishCasing("Hello"))
        #expect(MistypeDetector.hasEnglishCasing("NASA"))
        #expect(!MistypeDetector.hasEnglishCasing("wkRn"))
    }

    @Test func looseVowelsMeanLatin() {
        // pipefail → ㅔㅑㅔㄷㄹ먀ㅣ: 사전에 없지만 낱자 모음이 남는다
        #expect(detector.judge(keys: "pipefail", typedIn: .hangul) == .meantLatin("pipefail"))
        var detector = detector
        detector.thresholds.looseVowelMeansLatin = false
        #expect(detector.judge(keys: "pipefail", typedIn: .hangul) == .keep)
        detector.thresholds.looseVowelMeansLatin = true
        #expect(detector.judge(keys: "bbbb", typedIn: .hangul) == .keep)     // ㅠㅠㅠㅠ
        #expect(detector.judge(keys: "dkssud", typedIn: .hangul) == .keep)   // 안녕
    }

    @Test func nonLetterKeysAreKept() {
        #expect(detector.judge(keys: "abc1", typedIn: .latin) == .keep)
    }
}

@Suite("Mistype word tracker")
struct MistypeWordTrackerTests {
    static let detector: MistypeDetector = {
        var model = HangulSyllableModel()
        for word in ["안녕", "안녕하세요", "한글", "입력", "입력기"] { model.train(word: word, count: 20) }
        return MistypeDetector(lexicon: WordListLexicon(["hello", "world"]), model: model)
    }()

    /// 키 문자열을 친다. 공백은 단어 경계, "." 문장 부호, "<" 지우기, "1" 그 밖의 키, "^" 수정 키+스페이스(⌃Space 등).
    private func type(_ text: String, mode: TypingMode?, into tracker: inout MistypeWordTracker) -> [MistypeVerdict] {
        var verdicts: [MistypeVerdict] = []
        for char in text {
            let key: MistypeKey = switch char {
            case " ": .boundary
            case ".": .punctuation
            case "<": .edit
            case "1": .other
            case "^": .modifiedSpace
            default: .letter(char)
            }
            if let verdict = tracker.key(key, mode: mode) { verdicts.append(verdict) }
        }
        return verdicts
    }

    @Test func judgesAtWordBoundary() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud", mode: .latin, into: &tracker).isEmpty)       // 단어가 끝나기 전에는 판정하지 않는다
        #expect(type(" ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
        #expect(tracker.pendingKeyCount == 0)                                // 판정한 뒤 바로 지운다
        #expect(type("hello ", mode: .hangul, into: &tracker) == [.meantLatin("hello")])
        #expect(type("hello world ", mode: .latin, into: &tracker).isEmpty)
    }

    @Test func warnsWhileTypingOncePerWordWithPrefixes() {
        let detector = MistypeDetector(lexicon: WordListLexicon(["hello"]), model: Self.detector.model,
                                       prefixes: EnglishPrefixIndex(["hello", "help"]))
        var tracker = MistypeWordTracker(detector: detector)
        // 작은 테스트 모델에서는 "아"를 본 적이 없어 "안"이 확정되는 4타째에 알린다(실제 모델은 3타째, 앱 테스트)
        #expect(type("dks", mode: .latin, into: &tracker).isEmpty)
        #expect(type("s", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(tracker.lastWarningWasWhileTyping)
        #expect(type("ud ", mode: .latin, into: &tracker).isEmpty)                // 같은 단어는 한 번만
        #expect(type("hello ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("he", mode: .hangul, into: &tracker) == [.meantLatin("he")])
        #expect(type("llo ", mode: .hangul, into: &tracker).isEmpty)
    }

    @Test func boundaryWarningIsNotWhileTyping() {
        var tracker = MistypeWordTracker(detector: Self.detector) // 접두사 없음: 단어 끝에서만
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
        #expect(!tracker.lastWarningWasWhileTyping)
    }

    @Test func trailingPunctuationIsAllowed() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud. ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func lettersAfterPunctuationAreNotJudged() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud.dkssud ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")]) // 다음 단어는 다시 본다
    }

    @Test func editedWordsAreNotJudged() {
        // 고친 단어는 버린다(오타가 낱자 모음을 남겨 오탐이 나는 것을 막는다)
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssuf<d ", mode: .latin, into: &tracker).isEmpty)
    }

    private static var earlyDetector: MistypeDetector {
        MistypeDetector(lexicon: WordListLexicon(["hello"]), model: detector.model, prefixes: EnglishPrefixIndex(["hello", "help"]))
    }

    // 경고를 보고 단어를 다 지운 뒤 다시 치면, 다음 공백까지 판정이 멈춰 있었다.
    @Test func erasingAWholeLatinWordStartsAFreshWord() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        // 다 지운 뒤 모드를 바꿔 친 단어도 새 단어로 본다(지우기는 어느 모드에서 눌러도 영문 한 글자씩이다).
        #expect(type("<<<<", mode: .hangul, into: &tracker).isEmpty)
        #expect(type("he", mode: .hangul, into: &tracker) == [.meantLatin("he")])
    }

    @Test func erasingPastTheWordStartJoinsThePreviousWordAndStaysDropped() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("hello dks<<<<dkssud ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func partlyErasedOrHangulWordsWaitForTheNextBoundary() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dks<dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" ", mode: .latin, into: &tracker).isEmpty)
        // 한글 모드의 지우기는 낱자와 음절 중 무엇을 지웠는지 알 수 없다.
        #expect(type("hel", mode: .hangul, into: &tracker) == [.meantLatin("he")])
        #expect(type("<<<", mode: .hangul, into: &tracker).isEmpty)
        #expect(type("he", mode: .hangul, into: &tracker).isEmpty)
        #expect(type(" he", mode: .hangul, into: &tracker) == [.meantLatin("he")])
    }

    @Test func erasingAfterCursorKeysOrUnsupportedInputDoesNotGuessTheWordStart() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        // 화살표 등으로 커서가 움직였을 수 있다.
        #expect(type("dk1<<dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" ", mode: .latin, into: &tracker).isEmpty)
        // Caps Lock 등 판정하지 않는 입력으로 친 글자는 세지 않았다.
        #expect(type("dk", mode: .latin, into: &tracker).isEmpty)
        #expect(type("x", mode: nil, into: &tracker).isEmpty)
        #expect(type("<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker).isEmpty)
    }

    // ⌃Space 같은 입력 소스 전환은 커서를 옮기지 않는다. 단어 시작에서는 무시한다.
    @Test func switchingShortcutAtWordStartKeepsTheNextWord() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("hello ^", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<<<^", mode: .latin, into: &tracker).isEmpty)
        #expect(type("he", mode: .hangul, into: &tracker) == [.meantLatin("he")])
    }

    @Test func switchingShortcutInsideAWordDropsIt() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dk^ssud ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func otherKeysDropTheWord() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dks1sud ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("1dkssud ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
        #expect(type("dkssud", mode: .latin, into: &tracker).isEmpty)
        tracker.reset() // 마우스 클릭 등
        #expect(type(" ", mode: .latin, into: &tracker).isEmpty)
    }

    @Test func modeChangeInsideWordDropsIt() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dks", mode: .latin, into: &tracker).isEmpty)
        #expect(type("sud ", mode: .hangul, into: &tracker).isEmpty)
    }

    // Caps Lock 등 판정하지 않는 입력으로 친 글자도 화면에는 남는다("Xdkss"). 뒤 글자를 새 단어로 보면 오탐이 난다.
    @Test func unsupportedLetterAtWordStartDropsTheWord() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("x", mode: nil, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    // 판정하지 않는 입력으로 친 공백도 단어 경계다. 다음 단어는 다시 본다.
    @Test func unsupportedBoundaryStartsTheNextWord() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dk", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" ", mode: nil, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
        #expect(type("HELLO WORLD ", mode: nil, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func unsupportedSourceIsIgnored() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud ", mode: nil, into: &tracker).isEmpty)
        #expect(tracker.pendingKeyCount == 0)
    }

    @Test func tooLongWordsAreNotJudged() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        let long = String(repeating: "dkssud", count: 8) // 48타
        #expect(type(long + " ", mode: .latin, into: &tracker).isEmpty)
    }

    // MARK: - 엣지 케이스(2026-10-03: 지우기 복구, 수정 키+스페이스)

    @Test func keyLimitIsInclusive() {
        var tracker = MistypeWordTracker(detector: Self.detector)
        let limit = MistypeWordTracker.maximumKeys
        #expect(type(String(repeating: "x", count: limit), mode: .latin, into: &tracker).isEmpty)
        #expect(tracker.pendingKeyCount == limit)       // 40타까지는 모은다
        #expect(type("x", mode: .latin, into: &tracker).isEmpty)
        #expect(tracker.pendingKeyCount == 0)           // 41타째에 버린다
        #expect(type(" dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func erasingAnOverlongWordBackToItsStartStartsAFreshWord() {
        // 너무 길어 버린 단어도 영문 모드라면 지우기 수는 계속 센다
        let over = MistypeWordTracker.maximumKeys + 1
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type(String(repeating: "x", count: over), mode: .latin, into: &tracker).isEmpty)
        #expect(type(String(repeating: "<", count: over), mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])

        // 한 글자라도 남기면 다음 경계까지 버린다
        var partly = MistypeWordTracker(detector: Self.detector)
        #expect(type(String(repeating: "x", count: over), mode: .latin, into: &partly).isEmpty)
        #expect(type(String(repeating: "<", count: over - 1), mode: .latin, into: &partly).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &partly).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &partly) == [.meantHangul("안녕")])
    }

    @Test func erasingTrailingPunctuationCountsAsOneKey() {
        // "안녕." = 7타. 문장 부호까지 7번 지우면 단어 시작이다
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("ud.<<<<<<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])

        // 6번이면 첫 글자가 남는다
        var partly = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkssud.<<<<<<dkss", mode: .latin, into: &partly) == [.meantHangul("안ㄴ")]) // 처음 단어만
        #expect(type(" dkss", mode: .latin, into: &partly) == [.meantHangul("안ㄴ")])
    }

    @Test func erasingOnlyTheTrailingPunctuationDropsTheWord() {
        // 문장 부호만 지워도 고친 단어다(부분 지우기)
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud.< ", mode: .latin, into: &tracker).isEmpty)
    }

    @Test func leadingLatinPunctuationIsCountedForErasing() {
        // 단어 시작의 문장 부호(여는 따옴표 등)도 영문 한 글자다.
        // (문장 부호로 시작한 단어 자체를 판정할지는 여기서 보지 않는다.)
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        _ = type(".dkss", mode: .latin, into: &tracker)
        #expect(type("<<<<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        // 문장 부호를 남기면(4번) 커서가 단어 시작이 아니다
        _ = type(" .dkss", mode: .latin, into: &tracker)
        #expect(type("<<<<dkss", mode: .latin, into: &tracker).isEmpty)
    }

    @Test func erasingOnePastTheWordStartJoinsThePreviousWord() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<<<<", mode: .latin, into: &tracker).isEmpty) // 4번째에 단어 시작, 5번째는 앞 글자
        #expect(type("dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func repeatedFullErasesKeepWarning() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        for _ in 0..<3 {
            #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
            #expect(type("<<<<", mode: .latin, into: &tracker).isEmpty)
        }
    }

    @Test func partialEraseThenRetypeThenFullEraseStartsAFreshWord() {
        // 지운 뒤 다시 친 영문 글자도 센다: 4타 − 2 + 2 = 4번 지우면 단어 시작
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<ss", mode: .latin, into: &tracker).isEmpty)
        #expect(type("<<<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func fullEraseAlsoReenablesTheBoundaryJudgment() {
        // 접두사 없이 단어 끝에서만 판정하는 검출기: 다 지우고 다시 친 단어는 고친 단어가 아니다
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssuf<<<<<<dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func erasingAfterAModeMismatchDoesNotRecover() {
        // 단어 중간에 한글 모드로 친 글자는 조합되어 지우기 수를 알 수 없다
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dk", mode: .latin, into: &tracker).isEmpty)
        #expect(type("s", mode: .hangul, into: &tracker).isEmpty)
        #expect(type("<<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func erasingTheSpaceAfterABoundaryWarningDoesNotRewarn() {
        // 공백에서 알린 뒤 공백까지 지우면 앞 단어와 이어진다(지우기 수 0에서 지우기)
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
        #expect(type("<<<<<<<dkssud ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func resetRestartsTheCountAtTheClickedPosition() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        tracker.reset() // 클릭: 이 단어는 이미 알렸어도 새 단어로 본다
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        tracker.reset()
        // 클릭한 곳 앞의 글자를 지우면 그 앞 단어와 이어진다
        #expect(type("<dkss", mode: .latin, into: &tracker).isEmpty)
        // 반쯤 지운 뒤 클릭하면 셈이 0부터 다시 시작한다
        #expect(type(" dkss<<", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        tracker.reset()
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func switchingShortcutAfterTrailingPunctuationDropsTheWord() {
        // "안녕." 뒤는 아직 단어 시작이 아니다(.ended)
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(type("dkssud. ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
        #expect(type("dkssud.^ ", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkssud ", mode: .latin, into: &tracker) == [.meantHangul("안녕")])
    }

    @Test func switchingShortcutWhileErasingStopsTheCount() {
        // ⌥Space는 글자를 넣을 수 있으므로, 지우는 중에 끼면 단어 시작을 알 수 없다
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<^<<dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func switchingShortcutRightAfterAClickIsIgnored() {
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("xq", mode: .latin, into: &tracker).isEmpty)
        tracker.reset()
        #expect(type("^", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func switchingShortcutsAtWordStartDoNotStopTheCount() {
        // 단어 시작에서 무시한 ⌃Space는 지우기 수도 바꾸지 않는다
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("hello ^^dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }

    @Test func hangulModePunctuationStopsTheCount() {
        // 한글 모드의 문장 부호는 조합 중인 글자를 확정한다. 지우기 수와 맞는다고 보지 않는다
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type(".", mode: .hangul, into: &tracker).isEmpty)
        #expect(type("<<<<<dkss", mode: .latin, into: &tracker).isEmpty)
    }

    @Test func unsupportedKeysWhileErasingStopTheCount() {
        // Caps Lock을 켠 채 누른 지우기: 판정하지 않는 입력이 끼면 다음 경계까지 버린다
        var tracker = MistypeWordTracker(detector: Self.earlyDetector)
        #expect(type("dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
        #expect(type("<<", mode: .latin, into: &tracker).isEmpty)
        #expect(type("<<", mode: nil, into: &tracker).isEmpty)
        #expect(type("dkss", mode: .latin, into: &tracker).isEmpty)
        #expect(type(" dkss", mode: .latin, into: &tracker) == [.meantHangul("안ㄴ")])
    }
}

@Suite("Mistype key map and support")
struct MistypeKeyMapTests {
    @Test func mapsLetterKeyCodesByPosition() {
        #expect(MistypeKeyMap.key(keyCode: 0, shift: false, otherModifiers: false) == .letter("a"))
        #expect(MistypeKeyMap.key(keyCode: 15, shift: true, otherModifiers: false) == .letter("R")) // Shift+R = ㄲ
        #expect(MistypeKeyMap.key(keyCode: 46, shift: false, otherModifiers: false) == .letter("m"))
    }

    @Test func classifiesOtherKeys() {
        #expect(MistypeKeyMap.key(keyCode: 49, shift: false, otherModifiers: false) == .boundary) // space
        #expect(MistypeKeyMap.key(keyCode: 36, shift: false, otherModifiers: false) == .boundary) // return
        #expect(MistypeKeyMap.key(keyCode: 51, shift: false, otherModifiers: false) == .edit)     // delete
        #expect(MistypeKeyMap.key(keyCode: 47, shift: false, otherModifiers: false) == .punctuation) // .
        #expect(MistypeKeyMap.key(keyCode: 18, shift: true, otherModifiers: false) == .punctuation)  // !
        #expect(MistypeKeyMap.key(keyCode: 18, shift: false, otherModifiers: false) == .other)       // 1
        #expect(MistypeKeyMap.key(keyCode: 123, shift: false, otherModifiers: false) == .other)      // ←
        #expect(MistypeKeyMap.key(keyCode: 0, shift: false, otherModifiers: true) == .other)         // ⌘A
        #expect(MistypeKeyMap.key(keyCode: 49, shift: false, otherModifiers: true) == .modifiedSpace) // ⌃Space
        #expect(MistypeKeyMap.key(keyCode: 49, shift: true, otherModifiers: false) == .boundary)      // ⇧Space
    }

    @Test func modesForSources() {
        #expect(MistypeSupport.mode(forSourceID: InputSourceInfo.korean2Set.id) == .hangul)
        #expect(MistypeSupport.mode(forSourceID: InputSourceInfo.abc.id) == .latin)
        #expect(MistypeSupport.mode(forSourceID: InputSourceInfo.german.id) == nil)
    }

    @Test func availableOnlyWithBothLayouts() {
        let korean = InputSourceInfo.korean2Set.id, abc = InputSourceInfo.abc.id, german = InputSourceInfo.german.id
        #expect(MistypeSupport.isAvailable(enabledSourceIDs: [abc, korean]))
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [abc]))
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [german, korean]))
    }

    @Test func intendedSourceFollowsVerdict() {
        let ids = [InputSourceInfo.abc.id, InputSourceInfo.korean2Set.id]
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids) == InputSourceInfo.korean2Set.id)
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids) == InputSourceInfo.abc.id)
        #expect(MistypeSupport.intendedSourceID(for: .keep, enabledSourceIDs: ids) == nil)
    }

    // KeyHue's modes are two-set Korean and QWERTY. Without them the warning
    // stayed silent while typing in KeyHue and pointed at the system pair.
    @Test func keyHueModesAreRecognized() {
        #expect(MistypeSupport.mode(forSourceID: InputMethodIntegration.hangulID) == .hangul)
        #expect(MistypeSupport.mode(forSourceID: InputMethodIntegration.latinID) == .latin)
        #expect(MistypeSupport.isAvailable(enabledSourceIDs: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]))
        #expect(MistypeSupport.isAvailable(enabledSourceIDs: [InputSourceInfo.abc.id, InputMethodIntegration.hangulID]))
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [InputSourceInfo.german.id, InputMethodIntegration.hangulID]))
    }

    @Test func intendedSourceIsTheKeyHueModeOnlyWhileIntegrated() {
        let ids = [InputSourceInfo.abc.id, InputSourceInfo.korean2Set.id, InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids, integrated: true) == InputMethodIntegration.hangulID)
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids, integrated: true) == InputMethodIntegration.latinID)
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids, integrated: false) == InputSourceInfo.korean2Set.id)
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids, integrated: false) == InputSourceInfo.abc.id)
    }

    @Test func onlyKeyHueModesEnabledStillNameAnIntendedSource() {
        let ids = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids, integrated: false) == InputMethodIntegration.hangulID)
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids, integrated: false) == InputMethodIntegration.latinID)
    }

    // MARK: - 엣지 케이스(2026-10-03: KeyHue 입력기 모드)

    @Test func boundaryAndEditKeysIncludeTheirVariants() {
        #expect(MistypeKeyMap.key(keyCode: 76, shift: false, otherModifiers: false) == .boundary)      // 키패드 enter
        #expect(MistypeKeyMap.key(keyCode: 48, shift: false, otherModifiers: false) == .boundary)      // tab
        #expect(MistypeKeyMap.key(keyCode: 48, shift: true, otherModifiers: false) == .boundary)       // ⇧Tab
        #expect(MistypeKeyMap.key(keyCode: 117, shift: false, otherModifiers: false) == .edit)         // 앞으로 지우기
        #expect(MistypeKeyMap.key(keyCode: 51, shift: true, otherModifiers: false) == .edit)           // ⇧Delete
        // ⌘·⌥·⌃와 함께 누르면 스페이스 말고는 모두 그 밖의 키(단어를 버린다)
        #expect(MistypeKeyMap.key(keyCode: 51, shift: false, otherModifiers: true) == .other)          // ⌥Delete(단어 지우기)
        #expect(MistypeKeyMap.key(keyCode: 36, shift: false, otherModifiers: true) == .other)          // ⌘Return
        #expect(MistypeKeyMap.key(keyCode: 47, shift: false, otherModifiers: true) == .other)          // ⌘.
        #expect(MistypeKeyMap.key(keyCode: 49, shift: true, otherModifiers: true) == .modifiedSpace)   // ⌃⇧Space, ⌥⇧Space
    }

    @Test func punctuationKeysIgnoreShift() {
        for code: Int64 in [43, 47, 41, 39, 44] { // , . ; ' /
            #expect(MistypeKeyMap.key(keyCode: code, shift: false, otherModifiers: false) == .punctuation, "\(code)")
            #expect(MistypeKeyMap.key(keyCode: code, shift: true, otherModifiers: false) == .punctuation, "\(code)") // < > : " ?
        }
        // ! 말고 Shift+숫자는 문장 부호로 보지 않는다(@, #)
        #expect(MistypeKeyMap.key(keyCode: 19, shift: true, otherModifiers: false) == .other)
        #expect(MistypeKeyMap.key(keyCode: 33, shift: false, otherModifiers: false) == .other)            // [
    }

    @Test func letterKeysCoverTheAlphabetOnce() {
        let codes: [Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46]
        var letters = Set<Character>()
        for code in codes {
            guard case .letter(let letter) = MistypeKeyMap.key(keyCode: code, shift: false, otherModifiers: false) else {
                Issue.record("\(code) is not a letter"); continue
            }
            letters.insert(letter)
            #expect(MistypeKeyMap.key(keyCode: code, shift: true, otherModifiers: false) == .letter(Character(letter.uppercased())))
        }
        #expect(letters == Set("abcdefghijklmnopqrstuvwxyz"))
    }

    @Test func unknownSourceIDsHaveNoMode() {
        for id in ["", "com.apple.inputmethod.Korean", "com.apple.inputmethod.Korean.390Sebulshik",
                   "com.apple.keylayout.abc", "com.apple.keylayout.Dvorak", "com.apple.keylayout.Colemak",
                   "io.github.sejoung.keyhue.inputmethod.spike", InputMethodIntegration.hangulID.lowercased()] {
            #expect(MistypeSupport.mode(forSourceID: id) == nil, "\(id)")
        }
        for id in MistypeSupport.latinSourceIDs { #expect(MistypeSupport.mode(forSourceID: id) == .latin, "\(id)") }
        for id in MistypeSupport.hangulSourceIDs { #expect(MistypeSupport.mode(forSourceID: id) == .hangul, "\(id)") }
    }

    @Test func availabilityNeedsOneOfEachMode() {
        let korean = InputSourceInfo.korean2Set.id, abc = InputSourceInfo.abc.id
        let keyHueHangul = InputMethodIntegration.hangulID, keyHueLatin = InputMethodIntegration.latinID
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: []))
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [korean, korean]))
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [abc, abc, InputSourceInfo.us.id]))
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [korean, keyHueHangul]))     // 한글 둘
        #expect(!MistypeSupport.isAvailable(enabledSourceIDs: [abc, keyHueLatin]))         // 영문 둘
        #expect(MistypeSupport.isAvailable(enabledSourceIDs: [keyHueLatin, korean]))       // KeyHue 영문 + 시스템 두벌식
        #expect(MistypeSupport.isAvailable(enabledSourceIDs: [InputSourceInfo.german.id, keyHueLatin, keyHueHangul, keyHueHangul]))
    }

    @Test func intendedSourceIsTheFirstEnabledSystemLayout() {
        let us = InputSourceInfo.us.id, abc = InputSourceInfo.abc.id, korean = InputSourceInfo.korean2Set.id
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: [us, korean, abc]) == us)
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: [korean, abc, us]) == abc)
        // 연동이 아니면 KeyHue 모드가 먼저 켜져 있어도 시스템 배열을 고른다
        let ids = [InputMethodIntegration.latinID, InputMethodIntegration.hangulID, us, korean]
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids, integrated: false) == us)
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids, integrated: false) == korean)
    }

    @Test func intendedSourceWithOnlyKeyHueHangulAndSystemABC() {
        let ids = [InputMethodIntegration.hangulID, InputSourceInfo.abc.id]
        for integrated in [false, true] {
            #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids, integrated: integrated) == InputMethodIntegration.hangulID)
            #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids, integrated: integrated) == InputSourceInfo.abc.id)
        }
    }

    @Test func integratedFallsBackToSystemLayoutWhenTheKeyHueModeIsNotEnabled() {
        let ids = [InputSourceInfo.abc.id, InputSourceInfo.korean2Set.id, InputMethodIntegration.hangulID]
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: ids, integrated: true) == InputSourceInfo.abc.id)
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: ids, integrated: true) == InputMethodIntegration.hangulID)
    }

    @Test func noIntendedSourceWithoutALayoutForTheVerdict() {
        let german = InputSourceInfo.german.id
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: [], integrated: true) == nil)
        #expect(MistypeSupport.intendedSourceID(for: .meantLatin("hello"), enabledSourceIDs: [german, InputSourceInfo.korean2Set.id]) == nil)
        #expect(MistypeSupport.intendedSourceID(for: .meantHangul("안녕"), enabledSourceIDs: [german, InputMethodIntegration.latinID], integrated: true) == nil)
        #expect(MistypeSupport.intendedSourceID(for: .keep, enabledSourceIDs: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID], integrated: true) == nil)
    }
}

@Suite("Early mistype detection")
struct EarlyMistypeDetectionTests {
    static let detector = MistypeWordTrackerTests.detector
    static let prefixes = EnglishPrefixIndex(["hello", "help", "world", "the", "pipe"])

    /// 키를 하나씩 쳐서 처음 알린 시점(몇 타째)과 판정.
    private func firstTrigger(_ keys: String, _ mode: TypingMode,
                              _ t: MistypeDetector.EarlyThresholds = .init()) -> (Int, MistypeVerdict)? {
        var prefix = ""
        for key in keys {
            prefix.append(key)
            let f = Self.detector.earlyFeatures(keys: prefix, prefixes: Self.prefixes)!
            let verdict = MistypeDetector.judgeEarly(f, typedIn: mode, thresholds: t)
            if verdict != .keep { return (prefix.count, verdict) }
        }
        return nil
    }

    @Test func prefixIndexUsesBinarySearch() {
        #expect(Self.prefixes.hasWord(withPrefix: "hel"))
        #expect(Self.prefixes.hasWord(withPrefix: "HELLO"))
        #expect(!Self.prefixes.hasWord(withPrefix: "dk"))
        #expect(!Self.prefixes.hasWord(withPrefix: "worlds"))
        #expect(!EnglishPrefixIndex([]).hasWord(withPrefix: "a"))
    }

    @Test func englishInHangulModeIsCaughtOnceAVowelIsLeftAlone() {
        // h(ㅗ) e(ㄷ): 두 번째 키에서 ㅗ가 낱자로 확정된다
        let hit = firstTrigger("hello", .hangul)
        #expect(hit?.0 == 2)
        #expect(hit?.1 == .meantLatin("he"))
    }

    @Test func consonantOnlyEnglishIsCaughtWhileTyping() {
        // stro = ㄴㅅ개: 자음 낱자 2개가 확정됐고 영어 단어의 앞부분이다
        let prefixes = EnglishPrefixIndex(["string", "strong", "test", "gee"])
        func first(_ keys: String) -> Int? {
            var prefix = ""
            for key in keys {
                prefix.append(key)
                let f = Self.detector.earlyFeatures(keys: prefix, prefixes: prefixes)!
                if MistypeDetector.judgeEarly(f, typedIn: .hangul, thresholds: .init()) != .keep { return prefix.count }
            }
            return nil
        }
        #expect(first("strong") == 4)
        #expect(first("test") == 4)   // ㅅㄷㄴ까지는 초성체일 수 있어 기다린다
        #expect(first("gee") == nil)  // ㅎㄷㄷ
        #expect(first("ddrmf") == nil) // ㅇㅇ그: 영어 단어의 앞부분이 아니다
    }

    @Test func hangulTypoIsNotEnglish() {
        // 아ㅏ(dkk): 낱자 모음이 남았지만 영어 단어의 앞부분이 아니다
        #expect(firstTrigger("dkk", .hangul) == nil)
        #expect(firstTrigger("bbbb", .hangul) == nil) // ㅠㅠㅠㅠ
    }

    @Test func koreanInLatinModeIsCaughtBeforeTheWordEnds() {
        // dks = 안: 받침을 뺀 "아"는 확정. dk로 시작하는 영어 단어가 없다
        let hit = firstTrigger("dkssudgktpdy", .latin)
        #expect(hit != nil)
        #expect(hit!.0 <= 4)
        if case .meantHangul(let text)? = hit?.1 { #expect(text.hasPrefix("안")) } else { Issue.record("not hangul") }
    }

    @Test func englishPrefixesAreNotFlaggedInLatinMode() {
        #expect(firstTrigger("hello", .latin) == nil)
        #expect(firstTrigger("pipe", .latin) == nil)
    }

    @Test func plainShiftStopsLatinModeEarlyWarning() {
        #expect(firstTrigger("Dkssud", .latin) == nil)
    }

    @Test func minimumKeysApply() {
        #expect(firstTrigger("he", .hangul, .init(hangulMinimumKeys: 3)) == nil)
        #expect(firstTrigger("dkss", .latin, .init(latinMinimumKeys: 5)) == nil)
    }

    @Test func stableTextDropsTheFinalThatMayMove() {
        // 안 + 다음 모음이면 아나…가 되므로 "아"만 확정으로 본다
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "dks")) == "아")
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "dkss")) == "안")
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "dkk")) == nil) // 낱자 모음
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "d")) == nil)
    }
}

/// 코드 검토에서 찾은 엣지 케이스(회귀 방지).
@Suite("Mistype edge cases")
struct MistypeEdgeCaseTests {
    static let detector = MistypeWordTrackerTests.detector

    private func feed(_ tracker: inout MistypeWordTracker, _ keys: String, _ mode: TypingMode?) -> [MistypeVerdict] {
        keys.compactMap { char -> MistypeVerdict? in
            let key: MistypeKey = switch char {
            case " ": .boundary
            case "<": .edit
            default: .letter(char)
            }
            return tracker.key(key, mode: mode)
        }
    }

    @Test func capsLockInsideWordDropsTheWholeWord() {
        // Caps Lock(지원하지 않는 상태)이 단어 중간에 끼면 뒤 글자를 새 단어로 판정하지 않는다
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(feed(&tracker, "xq", .latin).isEmpty)
        #expect(feed(&tracker, "W", nil).isEmpty)
        #expect(feed(&tracker, "dkssud ", .latin).isEmpty)
        #expect(feed(&tracker, "dkssud ", .latin) == [.meantHangul("안녕")]) // 다음 단어는 다시 본다
    }

    @Test func backspaceRightAfterBoundaryDropsTheNextWord() {
        // 공백을 지우면 앞 단어와 이어진다(xq + dkssud). 조각만 판정하지 않는다
        var tracker = MistypeWordTracker(detector: Self.detector)
        #expect(feed(&tracker, "xq <dkssud ", .latin).isEmpty)
    }

    @Test(arguments: ["nb", "bn", "mn", "nmn", "bbzz", "zzbb", "zzzbb", "ggbb", "bbbb", "mm"])
    func koreanEmoticonsAreNotEnglish(_ keys: String) {
        // ㅜㅠ, ㅠㅜ, ㅡㅜ, ㅜㅡㅜ, ㅠㅠㅋㅋ, ㅋ큐ㅠ … 한글 모드에서 일부러 치는 표현
        let detector = MistypeDetector(lexicon: WordListLexicon(["mn", "nb"]), model: Self.detector.model)
        #expect(detector.judge(keys: keys, typedIn: .hangul) == .keep, "\(Dubeolsik.compose(keys: keys).text)")
    }

    @Test func stableTextExcludesAVowelThatCanStillCombine() {
        // 고 + ㅏ = 과: 받침 없는 ㅗ·ㅜ·ㅡ는 아직 바뀔 수 있다
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rh")) == nil)
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rhk")) == "과")
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "dkrh")) == "아")
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rhd")) == "고") // 받침이 생기면 모음은 바뀌지 않는다
    }

    @Test func modelParserAcceptsCRLFAndRejectsBrokenFiles() {
        var model = HangulSyllableModel()
        model.train(word: "안녕", count: 3)
        let text = model.serialized()
        #expect(HangulSyllableModel(serialized: text.replacingOccurrences(of: "\n", with: "\r\n")) == model)
        let header = "# KeyHue hangul syllable model v1\n"
        #expect(HangulSyllableModel(serialized: header + "가\t5\n가\t5\n") == nil)                   // 같은 줄이 두 번
        #expect(HangulSyllableModel(serialized: header + "가\t\(Int.max)\n나\t\(Int.max)\n") == nil) // 합이 넘친다
        #expect(HangulSyllableModel(serialized: header + "가\t-1\n") == nil)                         // 음수
    }
}

// MARK: - 엣지 케이스(2026-10-03: 두벌식 조합·음절 모델·판정기·치는 중 판정)

extension DubeolsikTests {
    @Test(arguments: [
        ("Rk", "까"), ("Ek", "따"), ("Qk", "빠"), ("Tk", "싸"), ("Wk", "짜"),
        ("dO", "얘"), ("dP", "예")
    ])
    func shiftProducesDoubleConsonantsAndVowels(keys: String, expected: String) {
        let c = Dubeolsik.compose(keys: keys)
        #expect(c.text == expected)
        #expect(c.isAllSyllables)
    }

    @Test func shiftOnKeysWithoutADoubleFormIsTheLowercaseJamo() {
        #expect(Dubeolsik.compose(keys: "DKSSUD").text == "안녕")
        #expect(Dubeolsik.compose(keys: "GKSDJ").text == "한어")
        #expect(Dubeolsik.compose(keys: "rK").text == "가")
        for key in "ASDFGHJKLZXCVBNMYUI" {
            #expect(Dubeolsik.jamo(forKey: key) == Dubeolsik.jamo(forKey: Character(key.lowercased())), "\(key)")
            #expect(Dubeolsik.isPlainShift(key), "\(key)")
        }
        for key in "QWERTOP" {
            #expect(Dubeolsik.jamo(forKey: key) != Dubeolsik.jamo(forKey: Character(key.lowercased())), "\(key)")
            #expect(!Dubeolsik.isPlainShift(key), "\(key)")
        }
        #expect(!Dubeolsik.isPlainShift("1"))
        #expect(Dubeolsik.jamo(forKey: "1") == nil)
        #expect(Dubeolsik.jamo(forKey: " ") == nil)
        #expect(Dubeolsik.jamo(forKey: "é") == nil)
        #expect(!Dubeolsik.compose(keys: "dké").isValid)
    }

    @Test(arguments: [
        ("rhk", "과"), ("rho", "괘"), ("rhl", "괴"), ("rnj", "궈"), ("rnp", "궤"), ("rnl", "귀"), ("rml", "긔")
    ])
    func composesEveryCompoundVowel(keys: String, expected: String) {
        let c = Dubeolsik.compose(keys: keys)
        #expect(c.text == expected)
        #expect(c.units == [.syllable(Character(expected))])
    }

    @Test func compoundVowelIsNotFormedAcrossAFinalOrFromNonPairs() {
        #expect(Dubeolsik.compose(keys: "rhrk").text == "고가")   // 곡 + ㅏ: 받침이 넘어가고 ㅘ가 되지 않는다
        #expect(Dubeolsik.compose(keys: "rkh").text == "가ㅗ")    // ㅏ + ㅗ는 겹모음이 아니다
        #expect(Dubeolsik.compose(keys: "rhkl").text == "과ㅣ")   // ㅘ + ㅣ는 겹모음이 아니다
    }

    @Test(arguments: [
        ("rkrt", "갃", "각사"), ("rksw", "갅", "간자"), ("rksg", "갆", "간하"), ("rkfr", "갉", "갈가"),
        ("rkfa", "갊", "갈마"), ("rkfq", "갋", "갈바"), ("rkft", "갌", "갈사"), ("rkfx", "갍", "갈타"),
        ("rkfv", "갎", "갈파"), ("rkfg", "갏", "갈하"), ("rkqt", "값", "갑사")
    ])
    func everyCompoundFinalFormsAndSplitsBeforeAVowel(keys: String, single: String, split: String) {
        #expect(Dubeolsik.compose(keys: keys).text == single)
        let c = Dubeolsik.compose(keys: keys + "k")
        #expect(c.text == split)            // 앞 자음은 남고 뒤 자음만 다음 음절의 초성이 된다
        #expect(c.isAllSyllables)
        #expect(c.syllableCount == 2)
    }

    @Test func doubleConsonantsAsFinals() {
        // ㄲ·ㅆ은 받침이 되고 모음이 오면 통째로 넘어간다
        #expect(Dubeolsik.compose(keys: "rkR").text == "갂")
        #expect(Dubeolsik.compose(keys: "rkRk").text == "가까")
        #expect(Dubeolsik.compose(keys: "rkT").text == "갔")
        #expect(Dubeolsik.compose(keys: "rkTk").text == "가싸")
        // ㄸ·ㅃ·ㅉ은 받침이 될 수 없어 새 글자가 된다
        #expect(Dubeolsik.compose(keys: "rkE").text == "가ㄸ")
        #expect(Dubeolsik.compose(keys: "rkQ").text == "가ㅃ")
        #expect(Dubeolsik.compose(keys: "rkW").text == "가ㅉ")
        #expect(Dubeolsik.compose(keys: "rkEk").text == "가따")
    }

    @Test func finalThatCannotCompoundStartsANewLetter() {
        #expect(Dubeolsik.compose(keys: "ekfrt").text == "닭ㅅ")   // ㄺ + ㅅ: 세 겹받침은 없다
        #expect(Dubeolsik.compose(keys: "rkrr").text == "각ㄱ")     // ㄱ + ㄱ은 겹받침이 아니다(ㄲ은 Shift로만)
    }

    @Test func leadingVowelsWithoutAnInitialStayLoose() {
        let vowel = Dubeolsik.compose(keys: "k")
        #expect(vowel.units == [.loose("ㅏ")])
        #expect(vowel.syllableCount == 0)
        #expect(!vowel.isAllSyllables)
        #expect(Dubeolsik.compose(keys: "krk").units == [.loose("ㅏ"), .syllable("가")])
        // 초성 없는 ㅗ + ㅏ도 ㅘ 한 글자로 묶인다(받침 넘기기와 같은 조합 규칙)
        #expect(Dubeolsik.compose(keys: "hk").units == [.loose("ㅘ")])
        #expect(Dubeolsik.compose(keys: "hks").units == [.loose("ㅘ"), .loose("ㄴ")])
    }

    @Test func consonantsWithoutAVowelStayLoose() {
        // 겹받침이 될 수 없는 자음만 이어 친 경우
        let c = Dubeolsik.compose(keys: "rew")
        #expect(c.text == "ㄱㄷㅈ")
        #expect(c.syllableCount == 0)
        #expect(c.looseJamoCount == 3)
        #expect(c.looseJamo == ["ㄱ", "ㄷ", "ㅈ"])
        #expect(c.isValid)
        #expect(!c.isAllSyllables)
    }

    @Test func committedUnitsDropOnlyTheLastLetter() {
        #expect(Array(Dubeolsik.compose(keys: "dkssud").committedUnits) == [.syllable("안")])
        #expect(Dubeolsik.compose(keys: "r").committedUnits.isEmpty)
    }

    @Test func veryLongInputComposesWithoutLoss() {
        let c = Dubeolsik.compose(keys: String(repeating: "dkssud", count: 2_000))
        #expect(c.text == String(repeating: "안녕", count: 2_000))
        #expect(c.syllableCount == 4_000)
        #expect(c.looseJamoCount == 0)
        #expect(c.units.count == 4_000)
    }

    @Test func keysForUsesShiftedKeysAndRejectsDecomposedHangul() {
        #expect(Dubeolsik.keys(for: "까") == "Rk")
        #expect(Dubeolsik.keys(for: "예") == "dP")
        #expect(Dubeolsik.keys(for: "값") == "rkqt")
        #expect(Dubeolsik.keys(for: "ㅘ") == "hk")
        // 조합형(NFD) 한글과 옛한글 자모는 키로 바꾸지 않는다
        #expect(Dubeolsik.keys(for: "\u{1100}\u{1161}") == nil)
        #expect(Dubeolsik.keys(for: "ㆍ") == nil)
        #expect(!Dubeolsik.isSyllable("\u{1100}\u{1161}"))
        #expect(!Dubeolsik.isSyllable("a"))
        #expect(Dubeolsik.isSyllable("힣"))
    }

    @Test func wordsTrimsOuterPunctuationAndDropsMixedTokens() {
        #expect(MistypeText.words(in: "(안녕), 한글!? API를 1번", script: .hangul) == ["안녕", "한글"])
        #expect(MistypeText.words(in: "\"Hello,\" didn't world. café x2 $ok", script: .latin) == ["Hello", "world", "ok"])
        #expect(MistypeText.words(in: "  \t ... ", script: .latin).isEmpty)
        #expect(MistypeText.words(in: "ㅋㅋ 안녕", script: .hangul) == ["안녕"]) // 낱자는 음절이 아니다
    }
}

extension HangulSyllableModelTests {
    @Test func untrainedModelGivesEveryWordTheUniformScore() {
        let model = HangulSyllableModel()
        let uniform = -log10(Double(HangulSyllableModel.syllableCount + 1))
        #expect(abs(model.score("가")! - uniform) < 1e-12)
        #expect(abs(model.score("힣뷁")! - uniform) < 1e-12)
        #expect(model.trainedTokens == 0)
    }

    @Test func unseenSyllablesStillGetAFiniteScore() {
        var model = HangulSyllableModel()
        model.train(word: "안녕", count: 100)
        let score = model.score("뷁")!
        #expect(score.isFinite)
        #expect(score < model.score("안녕")!)
    }

    @Test func emptyAndMixedWordsAreNotScored() {
        let model = HangulSyllableModel()
        #expect(model.score("") == nil)
        #expect(model.score("", isPrefix: true) == nil)
        #expect(model.score("안a") == nil)
        #expect(model.score("안 녕") == nil)
        var trained = model
        let trainedEmpty = trained.train(word: "")
        let trainedPunctuated = trained.train(word: "안녕!")
        #expect(!trainedEmpty)
        #expect(!trainedPunctuated)
        #expect(trained.trainedTokens == 0)
    }

    @Test func countIsEquivalentToRepeatedTraining() {
        var once = HangulSyllableModel()
        once.train(word: "안녕", count: 3)
        var repeated = HangulSyllableModel()
        for _ in 0..<3 { repeated.train(word: "안녕") }
        #expect(once == repeated)
        #expect(once.trainedTokens == 9)   // 음절 2개 + 끝 경계, 3번
        #expect(once.bigramCount == 3)     // #안, 안녕, 녕#
    }

    @Test func prefixScoreLeavesOutTheEndBoundary() {
        var model = HangulSyllableModel()
        model.train(word: "안녕", count: 10)
        // "안"으로 끝나는 단어는 본 적이 없지만 "안"으로 시작하는 단어는 흔하다
        #expect(model.score("안", isPrefix: true)! > model.score("안")!)
    }

    @Test func smoothingAndWeightChangeUnseenScores() {
        var light = HangulSyllableModel(unigramSmoothing: 0.1)
        var heavy = HangulSyllableModel(unigramSmoothing: 5)
        light.train(word: "안녕", count: 10)
        heavy.train(word: "안녕", count: 10)
        // 평활화가 클수록 고르게 퍼져, 학습한 단어의 점수는 낮아진다(학습하지 않은 모델은 평활화와 상관없이 균등)
        #expect(light.score("안녕")! > heavy.score("안녕")!)
        #expect(abs(HangulSyllableModel(unigramSmoothing: 0.1).score("뷁")! - HangulSyllableModel(unigramSmoothing: 5).score("뷁")!) < 1e-12)
        var bigramOnly = HangulSyllableModel(bigramWeight: 0.99)
        bigramOnly.train(word: "안녕", count: 10)
        var unigramOnly = HangulSyllableModel(bigramWeight: 0.01)
        unigramOnly.train(word: "안녕", count: 10)
        #expect(bigramOnly.score("안녕")! > unigramOnly.score("안녕")!)
    }

    @Test func parserRejectsMalformedLines() {
        let header = "# KeyHue hangul syllable model v1\n"
        #expect(HangulSyllableModel(serialized: header + "가\t1\t2\n") == nil)   // 칸이 셋
        #expect(HangulSyllableModel(serialized: header + "가\n") == nil)         // 횟수 없음
        #expect(HangulSyllableModel(serialized: header + "가나다\t1\n") == nil)   // 글자 셋
        #expect(HangulSyllableModel(serialized: header + "가\t1\n가나\t1\n가나\t1\n") == nil) // bigram이 두 번
        #expect(HangulSyllableModel(serialized: "# KeyHue hangul syllable model v2\n가\t1\n") == nil)
        // 빈 줄은 건너뛴다
        #expect(HangulSyllableModel(serialized: header + "\n가\t1\n\n") != nil)
    }
}

extension MistypeDetectorTests {
    @Test func meaningfulShiftDoesNotBlockLatinToHangul() {
        // 있습니다: Shift+T(ㅆ)는 한글을 칠 때도 누른다
        #expect(detector.judge(keys: "dlTtmqslek", typedIn: .latin) == .meantHangul("있습니다"))
    }

    @Test func allUppercaseWords() {
        #expect(detector.judge(keys: "DKSSUD", typedIn: .latin) == .keep)                     // 의미 없는 Shift
        #expect(detector.judge(keys: "HELLO", typedIn: .hangul) == .meantLatin("HELLO"))       // 모두 대문자도 영어 표기
        #expect(detector.judge(keys: "Hello", typedIn: .hangul) == .meantLatin("Hello"))
        #expect(detector.judge(keys: "Test", typedIn: .hangul) == .meantLatin("Test"))         // ㅆㄷㄴㅅ
        #expect(detector.judge(keys: "Hello", typedIn: .latin) == .keep)
    }

    @Test func dictionaryWordThatLooksKoreanStaysInLatinMode() {
        // when = 조두: 한국어 점수가 높아도 영어 사전에 있으면 영문 모드에서 그대로 둔다
        var model = HangulSyllableModel()
        model.train(word: "조두", count: 50)
        let withWord = MistypeDetector(lexicon: WordListLexicon(["when"]), model: model)
        let withoutWord = MistypeDetector(lexicon: WordListLexicon([]), model: model)
        #expect(withWord.judge(keys: "when", typedIn: .latin) == .keep)
        #expect(withoutWord.judge(keys: "when", typedIn: .latin) == .meantHangul("조두"))
    }

    @Test func defaultRejectScoreKeepsKoreanLookingEnglishUnlessPlainShift() {
        // dot = 앳(ADR 0041): 흔한 한글이면 한글 모드에서 그대로 둔다. 의미 없는 Shift가 있으면 점수보다 우선한다
        var model = HangulSyllableModel()
        model.train(word: "앳", count: 50)
        let detector = MistypeDetector(lexicon: WordListLexicon(["dot"]), model: model)
        #expect(detector.judge(keys: "dot", typedIn: .hangul) == .keep)
        #expect(detector.judge(keys: "Dot", typedIn: .hangul) == .meantLatin("Dot"))
        #expect(detector.judge(keys: "DOT", typedIn: .hangul) == .meantLatin("DOT"))   // 얬
    }

    @Test func minimumKeysAreInclusive() {
        var model = HangulSyllableModel()
        model.train(word: "안", count: 50)
        model.train(word: "아", count: 50)
        let detector = MistypeDetector(lexicon: WordListLexicon(["he"]), model: model)
        #expect(detector.judge(keys: "dk", typedIn: .latin) == .keep)               // 2타
        #expect(detector.judge(keys: "dks", typedIn: .latin) == .meantHangul("안"))  // 3타부터
        #expect(detector.judge(keys: "h", typedIn: .hangul) == .keep)               // 1타
        #expect(detector.judge(keys: "he", typedIn: .hangul) == .meantLatin("he"))   // 2타부터
    }

    @Test func mixedKoreanAndEnglishKeys() {
        // 안녕 + hello를 붙여 친 단어: 영문 모드에서는 낱자가 남아 한글로 보지 않는다
        #expect(detector.judge(keys: "dkssudhello", typedIn: .latin) == .keep)
        // 한글 모드에서는 낱자 모음(ㅗ, ㅣ, ㅐ)이 남아 영어로 본다
        #expect(detector.judge(keys: "dkssudhello", typedIn: .hangul) == .meantLatin("dkssudhello"))
    }

    @Test func consonantOnlyLexiconMissIsKeptInHangulMode() {
        // zxcv = ㅋㅌㅊㅍ: 사전에 없고 낱자 모음도 없으면 판단하지 않는다(초성 약어일 수 있다)
        #expect(detector.judge(keys: "zxcv", typedIn: .hangul) == .keep)
        // 사전에 없는 음절 단어도 그대로
        #expect(detector.judge(keys: "rkqt", typedIn: .hangul) == .keep)
    }

    @Test func emptyAndPunctuatedKeysAreKeptWithoutFeatures() {
        #expect(detector.features(keys: "") == nil)
        #expect(detector.judge(keys: "", typedIn: .latin) == .keep)
        #expect(detector.judge(keys: "", typedIn: .hangul) == .keep)
        for keys in ["dkssud.", "don't", "hello world", "hello!"] {
            #expect(detector.features(keys: keys) == nil, "\(keys)")
            #expect(detector.judge(keys: keys, typedIn: .hangul) == .keep, "\(keys)")
            #expect(detector.judge(keys: keys, typedIn: .latin) == .keep, "\(keys)")
        }
    }

    @Test func englishCasingEdgeCases() {
        #expect(MistypeDetector.hasEnglishCasing("a"))
        #expect(MistypeDetector.hasEnglishCasing("A"))
        #expect(!MistypeDetector.hasEnglishCasing("ABc"))
        #expect(!MistypeDetector.hasEnglishCasing("aBC"))
        // 사전은 대소문자를 구분하지 않지만 casing이 틀리면 단어로 치지 않는다
        #expect(detector.features(keys: "HeLLo")?.latinIsWord == false)
        #expect(detector.features(keys: "HELLO")?.latinIsWord == true)
    }

    @Test func singleRepeatedLooseVowelIsAnExpression() {
        // ㅏㅏㅏㅏ: 낱자 모음이 남아도 같은 낱자 반복은 한국어 표현
        #expect(detector.judge(keys: "kkkk", typedIn: .hangul) == .keep)
        #expect(MistypeDetector.isJamoExpression(Dubeolsik.compose(keys: "kkkk")))
        // 초성체는 세 타까지만 표현으로 본다
        #expect(MistypeDetector.isJamoExpression(Dubeolsik.compose(keys: "rew")))
        #expect(!MistypeDetector.isJamoExpression(Dubeolsik.compose(keys: "zxcv")))
    }
}

extension EarlyMistypeDetectionTests {
    @Test func prefixIndexBoundaries() {
        let index = EnglishPrefixIndex(["abc", "abd", "Hello", "", "hello"])
        #expect(index.count == 3)                          // 빈 단어는 빼고, 대소문자가 다른 같은 단어는 하나
        #expect(index.hasWord(withPrefix: "ab"))
        #expect(index.hasWord(withPrefix: "abd"))           // 단어 전체도 앞부분
        #expect(!index.hasWord(withPrefix: "abe"))          // 두 단어 사이
        #expect(!index.hasWord(withPrefix: "aa"))           // 맨 앞보다 앞
        #expect(!index.hasWord(withPrefix: "zzz"))          // 맨 뒤보다 뒤
        #expect(!index.hasWord(withPrefix: "helloo"))
        #expect(index.hasWord(withPrefix: ""))              // 빈 앞부분은 모든 단어
        #expect(!EnglishPrefixIndex([""]).hasWord(withPrefix: ""))
    }

    @Test func withoutPrefixesEarlyJudgmentIsOff() {
        #expect(Self.detector.prefixes == nil)
        #expect(Self.detector.judgeEarly(keys: "dkss", typedIn: .latin) == .keep)
        #expect(Self.detector.judgeEarly(keys: "hel", typedIn: .hangul) == .keep)
    }

    @Test func nonLetterKeysHaveNoEarlyFeatures() {
        #expect(Self.detector.earlyFeatures(keys: "", prefixes: Self.prefixes) == nil)
        #expect(Self.detector.earlyFeatures(keys: "he'", prefixes: Self.prefixes) == nil)
    }

    @Test func casingDecidesWhetherKeysAreAnEnglishPrefix() {
        // 모두 대문자(ㅗㄸ)와 첫 글자 대문자는 영어 표기, 가운데 대문자(hE)는 쌍자음이다
        #expect(firstTrigger("HE", .hangul)?.1 == .meantLatin("HE"))
        #expect(firstTrigger("He", .hangul)?.1 == .meantLatin("He"))
        #expect(firstTrigger("hE", .hangul) == nil)
    }

    @Test func latinMinimumKeysIsInclusive() {
        // 아·안이 흔한 모델: dk(아)는 2타라 기다리고 3타째에 알린다
        var model = HangulSyllableModel()
        for word in ["아이", "안녕", "앙금"] { model.train(word: word, count: 20) }
        let detector = MistypeDetector(lexicon: WordListLexicon([]), model: model, prefixes: Self.prefixes)
        #expect(detector.judgeEarly(keys: "dk", typedIn: .latin) == .keep)
        #expect(detector.judgeEarly(keys: "dkd", typedIn: .latin) == .meantHangul("앙"))
        var eager = detector
        eager.earlyThresholds.latinMinimumKeys = 2
        #expect(eager.judgeEarly(keys: "dk", typedIn: .latin) == .meantHangul("아"))
    }

    @Test func consonantRuleCanBeTurnedOff() {
        let prefixes = EnglishPrefixIndex(["test", "string"])
        let detector = MistypeDetector(lexicon: WordListLexicon([]), model: Self.detector.model, prefixes: prefixes)
        #expect(detector.judgeEarly(keys: "test", typedIn: .hangul) == .meantLatin("test"))
        var off = detector
        off.earlyThresholds.hangulConsonantRun = nil
        #expect(off.judgeEarly(keys: "test", typedIn: .hangul) == .keep)
        // 자음 낱자는 2개 이상 "확정"돼야 한다: ㅅㄷ(2타)은 ㅅ 하나만 확정
        #expect(detector.judgeEarly(keys: "te", typedIn: .hangul) == .keep)
    }

    @Test func optionalStableScoreRule() {
        // the = 솓: 받침을 뺀 "소"가 확정된다. 점수 규칙은 기본으로 쓰지 않는다
        #expect(firstTrigger("the", .hangul) == nil)
        let hit = firstTrigger("the", .hangul, .init(hangulRejectStable: 0))
        #expect(hit?.0 == 3)
        #expect(hit?.1 == .meantLatin("the"))
    }

    @Test func committedConsonantsOnlyCountsOnlyWithoutSyllablesOrVowels() {
        func run(_ keys: String) -> Int? { Self.detector.earlyFeatures(keys: keys, prefixes: Self.prefixes)?.committedConsonantsOnly }
        #expect(run("str") == 2)    // ㄴㅅ + ㄱ(아직 바뀔 수 있음)
        #expect(run("s") == 0)
        #expect(run("dkss") == 0)   // 안 + ㄴ
        #expect(run("hel") == 0)    // ㅗ + 디: 낱자 모음
    }

    @Test func stableTextEdgeCases() {
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "dkssudr")) == "안녕")  // 마지막 낱자 자음은 빼고 본다
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rrk")) == nil)        // 확정된 낱자 자음
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "ekfr")) == "다")       // 겹받침은 통째로 뺀다
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rn")) == nil)         // ㅜ는 ㅝ·ㅞ·ㅟ가 될 수 있다
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rm")) == nil)         // ㅡ는 ㅢ가 될 수 있다
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rnj")) == "궈")
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "rml")) == "긔")
        #expect(MistypeDetector.stableText(Dubeolsik.compose(keys: "hk")) == nil)          // 낱자 겹모음
    }
}
