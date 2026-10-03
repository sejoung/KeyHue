import Testing
@testable import KeyHueCore

extension InputSourceInfo {
    static let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", localizedName: "ABC", languages: ["en"], isASCIICapable: true)
    static let us = InputSourceInfo(id: "com.apple.keylayout.US", localizedName: "U.S.", languages: ["en"], isASCIICapable: true)
    static let dvorak = InputSourceInfo(id: "com.apple.keylayout.Dvorak", localizedName: "Dvorak", languages: ["en"], isASCIICapable: true)
    static let german = InputSourceInfo(id: "com.apple.keylayout.German", localizedName: "German", languages: ["de"], isASCIICapable: true)
    static let korean2Set = InputSourceInfo(
        id: "com.apple.inputmethod.Korean.2SetKorean",
        localizedName: "2-Set Korean",
        languages: ["ko"],
        isASCIICapable: false
    )
    static let gureumHan = InputSourceInfo(
        id: "org.youknowone.inputmethod.Gureum.han2",
        localizedName: "Gureum 2-Set",
        languages: ["ko", "en"],
        isASCIICapable: false
    )
    static let hiragana = InputSourceInfo(
        id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
        localizedName: "Hiragana",
        languages: ["ja"],
        isASCIICapable: false
    )
    static let katakana = InputSourceInfo(
        id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese.Katakana",
        localizedName: "Katakana",
        languages: ["ja"],
        isASCIICapable: false
    )
    /// 일본어 입력기의 영숫자 모드. ASCII 입력이 가능해도 CJK 입력기이므로 기본 영문 그룹이 아니다.
    static let japaneseRoman = InputSourceInfo(
        id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman",
        localizedName: "Romaji",
        languages: ["ja"],
        isASCIICapable: true
    )
    static let pinyin = InputSourceInfo(id: "com.apple.inputmethod.SCIM.ITABC", localizedName: "Pinyin - Simplified", languages: ["zh-Hans"], isASCIICapable: false)
    static let russian = InputSourceInfo(id: "com.apple.keylayout.Russian", localizedName: "Russian", languages: ["ru"], isASCIICapable: false)
    static let greek = InputSourceInfo(id: "com.apple.keylayout.Greek", localizedName: "Greek", languages: ["el"], isASCIICapable: false)
    static let georgian = InputSourceInfo(id: "com.apple.keylayout.Georgian-QWERTY", localizedName: "Georgian", languages: ["ka"], isASCIICapable: false)
}

@Suite("Input source grouping")
struct InputSourceGroupingTests {
    @Test(arguments: [InputSourceInfo.abc, .us, .dvorak, .german])
    func latinLayoutsAreASCIIBase(_ info: InputSourceInfo) {
        #expect(info.isASCIIBase)
    }

    @Test(arguments: [InputSourceInfo.korean2Set, .gureumHan, .hiragana, .japaneseRoman, .pinyin, .russian, .greek])
    func nativeScriptsAreNotBase(_ info: InputSourceInfo) {
        #expect(!info.isASCIIBase)
    }

    @Test func primaryLanguageStripsRegion() {
        #expect(InputSourceInfo.pinyin.primaryLanguage == "zh")
        let info = InputSourceInfo(id: "x", localizedName: "x", languages: ["ko-KR"], isASCIICapable: false)
        #expect(info.primaryLanguage == "ko")
        #expect(InputSourceInfo(id: "x", localizedName: "x", languages: [], isASCIICapable: false).primaryLanguage == "")
    }
}

@Suite("Input state resolution")
struct InputStateResolveTests {
    @Test func capsLockHasPriority() {
        #expect(InputState.resolve(source: .korean2Set, isCapsLockOn: true) == .capsLock)
        #expect(InputState.resolve(source: nil, isCapsLockOn: true) == .capsLock)
    }

    @Test func capsLockOffShowsSource() {
        #expect(InputState.resolve(source: .korean2Set, isCapsLockOn: false) == .source(.korean2Set))
        #expect(InputState.resolve(source: nil, isCapsLockOn: false) == .unknown)
    }
}

@Suite("Default source palette")
struct SourcePaletteTests {
    @Test func koreanUserKeepsGreenAndBlue() {
        #expect(SourcePalette.defaultColor(for: .korean2Set).hexString == "#34C759")
        #expect(SourcePalette.defaultColor(for: .gureumHan).hexString == "#34C759")
        #expect(SourcePalette.defaultColor(for: .abc).hexString == "#0A84FF")
    }

    @Test func allLatinLayoutsShareBaseColor() {
        for info in [InputSourceInfo.abc, .us, .dvorak, .german] {
            #expect(SourcePalette.defaultColor(for: info) == SourcePalette.base)
        }
    }

    @Test func majorLanguagesGetDistinctColors() {
        let colors = [InputSourceInfo.abc, .korean2Set, .hiragana, .pinyin, .russian, .greek].map(SourcePalette.defaultColor)
        #expect(Set(colors).count == colors.count)
    }

    @Test func neverUsesCapsLockRed() {
        let languages = ["ko", "ja", "zh", "ru", "el", "ar", "he", "th", "hi", "ka", "hy", "ta", "km", "am", "xx", ""]
        for language in languages {
            let info = InputSourceInfo(id: "test.\(language)", localizedName: language, languages: [language], isASCIICapable: false)
            #expect(SourcePalette.defaultColor(for: info) != RGBAColor.defaultCapsLock)
        }
    }

    @Test func fallbackIsStableAcrossCalls() {
        #expect(SourcePalette.defaultColor(for: .georgian) == SourcePalette.defaultColor(for: .georgian))
        #expect(SourcePalette.stableHash("ka") == SourcePalette.stableHash("ka"))
    }
}

@MainActor
@Suite("InputStateStore")
struct InputStateStoreTests {
    @Test func notifiesOnlyOnChange() {
        let store = InputStateStore()
        var changes: [(InputState, InputState)] = []
        store.addObserver { old, new in changes.append((old.state, new.state)) }

        store.updateSource(.korean2Set)
        store.updateSource(.korean2Set) // 중복 notification
        store.updateCapsLock(false)     // 이미 false
        #expect(changes.count == 1)
        #expect(changes[0].0 == .unknown)
        #expect(changes[0].1 == .source(.korean2Set))
    }

    @Test func capsLockRestoresSourceState() {
        let store = InputStateStore()
        store.updateSource(.korean2Set)
        store.updateCapsLock(true)
        #expect(store.state == .capsLock)
        store.updateCapsLock(false)
        #expect(store.state == .source(.korean2Set))
    }

    @Test func switchingBetweenLatinLayoutsChangesState() {
        let store = InputStateStore()
        store.updateSource(.abc)
        var count = 0
        store.addObserver { _, _ in count += 1 }
        store.updateSource(.german)
        #expect(count == 1)
        #expect(store.state == .source(.german))
    }

    @Test func sourceChangeWhileCapsLockKeepsCapsState() {
        let store = InputStateStore()
        store.updateCapsLock(true)
        store.updateSource(.korean2Set)
        #expect(store.state == .capsLock)
        #expect(store.snapshot.source == .korean2Set)
    }
}

// MARK: - 엣지 케이스

@Suite("Input source edge cases")
struct InputSourceEdgeTests {
    private func source(_ languages: [String], ascii: Bool, id: String = "test.source") -> InputSourceInfo {
        InputSourceInfo(id: id, localizedName: "Test", languages: languages, isASCIICapable: ascii)
    }

    @Test func primaryLanguageIgnoresCaseAndSeparators() {
        #expect(source(["ZH_Hant_TW"], ascii: false).primaryLanguage == "zh")
        #expect(source(["KO"], ascii: false).primaryLanguage == "ko")
        #expect(source(["yue-Hant-HK", "zh"], ascii: false).primaryLanguage == "yue")
    }

    @Test func groupingWithOddLanguageLists() {
        // 언어 정보가 없으면 ASCII 입력 가능 여부만 본다
        #expect(source([], ascii: true).isASCIIBase)
        #expect(!source([], ascii: false).isASCIIBase)
        // 영어라고 알리면 ASCII 플래그가 없어도 영문 배열이다(대소문자 무관)
        #expect(source(["EN-us"], ascii: false).isASCIIBase)
        // CJK 입력기는 ASCII 입력이 가능하다고 해도, 지역 태그가 붙어도 영문 배열이 아니다
        #expect(!source(["zh-Hans"], ascii: true).isASCIIBase)
        #expect(!source(["yue-Hant"], ascii: true).isASCIIBase)
        #expect(!source(["ja-JP"], ascii: true).isASCIIBase)
        #expect(!source(["KO_kr"], ascii: true).isASCIIBase)
    }

    @Test func regionalTagsGetTheLanguageColor() {
        #expect(SourcePalette.defaultColor(for: source(["ko-KR"], ascii: false)) == SourcePalette.defaultColor(for: .korean2Set))
        #expect(SourcePalette.defaultColor(for: source(["ru_RU"], ascii: false)) == SourcePalette.defaultColor(for: .russian))
        #expect(SourcePalette.defaultColor(for: source(["zh-Hant-TW"], ascii: false)) == SourcePalette.defaultColor(for: .pinyin))
        #expect(SourcePalette.defaultColor(for: source(["EL"], ascii: false)) == SourcePalette.defaultColor(for: .greek))
        #expect(SourcePalette.defaultColor(for: source(["he-IL"], ascii: false)).hexString == "#FFCC00")
    }

    @Test func stableHashMatchesFNV1aReferenceValues() {
        // 해시가 바뀌면 업데이트 후 사용자의 기본색이 바뀐다. FNV-1a 64비트 공개 테스트 값으로 고정한다.
        #expect(SourcePalette.stableHash("") == 0xcbf29ce484222325)
        #expect(SourcePalette.stableHash("a") == 0xaf63dc4c8601ec8c)
        #expect(SourcePalette.stableHash("foobar") == 0x85944171f73967e8)
    }

    @Test func colorOfASourceWithoutLanguageDependsOnlyOnItsID() {
        let first = source([], ascii: false, id: "com.example.symbols")
        var renamed = first
        renamed.localizedName = "Renamed"
        #expect(SourcePalette.defaultColor(for: first) == SourcePalette.defaultColor(for: renamed))
        #expect(SourcePalette.defaultColor(for: first) != SourcePalette.base)
        #expect(SourcePalette.defaultColor(for: first) != RGBAColor.defaultCapsLock)
    }
}

@MainActor
@Suite("InputStateStore edge cases")
struct InputStateStoreEdgeTests {
    @Test func sourceChangeHiddenByCapsLockIsStillReported() {
        // 화면은 Caps Lock 그대로지만, 끄는 순간 새 입력 소스를 보여야 하므로 값 변화는 알린다
        let store = InputStateStore()
        store.updateSource(.abc)
        store.updateCapsLock(true)
        var changes: [(InputSnapshot, InputSnapshot)] = []
        store.addObserver { changes.append(($0, $1)) }
        store.updateSource(.korean2Set)
        #expect(changes.count == 1)
        #expect(changes.first?.0.state == .capsLock)
        #expect(changes.first?.1.state == .capsLock)
        #expect(changes.first?.0.source == .abc)
        #expect(changes.first?.1.source == .korean2Set)
    }

    @Test func losingTheSourceShowsUnknown() {
        let store = InputStateStore()
        store.updateSource(.korean2Set)
        var states: [InputState] = []
        store.addObserver { _, new in states.append(new.state) }
        store.updateSource(nil)
        store.updateSource(nil)
        #expect(states == [.unknown])
        #expect(store.snapshot == InputSnapshot())
    }

    @Test func everyObserverIsCalledInOrderWithTheSameChange() {
        let store = InputStateStore()
        var calls: [String] = []
        store.addObserver { _, new in calls.append("a \(new.isCapsLockOn)") }
        store.addObserver { _, new in calls.append("b \(new.isCapsLockOn)") }
        store.updateCapsLock(true)
        store.updateCapsLock(true)
        store.updateCapsLock(false)
        #expect(calls == ["a true", "b true", "a false", "b false"])
    }

    @Test func observerSeesTheStoreAlreadyUpdated() {
        // observer 안에서 store를 다시 읽어도 새 값이다(UI가 store.state를 읽는 경우)
        let store = InputStateStore()
        var seen: InputState?
        store.addObserver { _, _ in seen = store.state }
        store.updateSource(.hiragana)
        #expect(seen == .source(.hiragana))
    }
}
