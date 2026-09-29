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

    @Test func hudGlyphs() {
        #expect(InputState.source(.korean2Set).hudGlyph == "가")
        #expect(InputState.source(.abc).hudGlyph == "a")
        #expect(InputState.source(.german).hudGlyph == "a")
        #expect(InputState.source(.hiragana).hudGlyph == "あ")
        #expect(InputState.source(.katakana).hudGlyph == "ア")
        #expect(InputState.source(.pinyin).hudGlyph == "中")
        #expect(InputState.source(.russian).hudGlyph == "Я")
        #expect(InputState.source(.greek).hudGlyph == "α")
        #expect(InputState.capsLock.hudGlyph == "A")
    }

    @Test func unknownLanguageUsesFirstLetterOfName() {
        let info = InputSourceInfo(id: "x.Tamil", localizedName: "Tamil", languages: ["ta"], isASCIICapable: false)
        #expect(InputSourceGlyph.glyph(for: info) == "T")
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
