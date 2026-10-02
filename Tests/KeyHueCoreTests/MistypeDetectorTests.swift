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
