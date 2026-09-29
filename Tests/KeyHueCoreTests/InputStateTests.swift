import Testing
@testable import KeyHueCore

extension InputSourceInfo {
    static let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", localizedName: "ABC", languages: ["en"], isASCIICapable: true)
    static let us = InputSourceInfo(id: "com.apple.keylayout.US", localizedName: "U.S.", languages: ["en"], isASCIICapable: true)
    static let dvorak = InputSourceInfo(id: "com.apple.keylayout.Dvorak", localizedName: "Dvorak", languages: ["en"], isASCIICapable: true)
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
    static let japaneseKana = InputSourceInfo(
        id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
        localizedName: "Hiragana",
        languages: ["ja"],
        isASCIICapable: false
    )
    static let german = InputSourceInfo(id: "com.apple.keylayout.German", localizedName: "German", languages: ["de"], isASCIICapable: true)
}

@Suite("Input source classification")
struct InputSourceClassifierTests {
    @Test(arguments: [InputSourceInfo.korean2Set, .gureumHan])
    func koreanSources(_ info: InputSourceInfo) {
        #expect(info.kind == .korean)
    }

    @Test(arguments: [InputSourceInfo.abc, .us, .dvorak, .german])
    func asciiCapableSourcesAreEnglish(_ info: InputSourceInfo) {
        #expect(info.kind == .english)
    }

    @Test func nonKoreanIMEIsOther() {
        #expect(InputSourceInfo.japaneseKana.kind == .other)
    }

    @Test func regionTaggedLanguage() {
        let info = InputSourceInfo(id: "x", localizedName: "x", languages: ["ko-KR"], isASCIICapable: false)
        #expect(info.kind == .korean)
    }
}

@Suite("Input state resolution")
struct InputStateResolveTests {
    @Test func capsLockHasPriority() {
        #expect(InputState.resolve(sourceKind: .korean, isCapsLockOn: true) == .capsLock)
        #expect(InputState.resolve(sourceKind: .english, isCapsLockOn: true) == .capsLock)
        #expect(InputState.resolve(sourceKind: nil, isCapsLockOn: true) == .capsLock)
    }

    @Test func capsLockOffFallsBackToSource() {
        #expect(InputState.resolve(sourceKind: .korean, isCapsLockOn: false) == .korean)
        #expect(InputState.resolve(sourceKind: .english, isCapsLockOn: false) == .english)
        #expect(InputState.resolve(sourceKind: .other, isCapsLockOn: false) == .unknown)
        #expect(InputState.resolve(sourceKind: nil, isCapsLockOn: false) == .unknown)
    }

    @Test func hudGlyphs() {
        #expect(InputState.korean.hudGlyph == "가")
        #expect(InputState.english.hudGlyph == "a")
        #expect(InputState.capsLock.hudGlyph == "A")
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
        #expect(changes[0] == (.unknown, .korean))
    }

    @Test func capsLockRestoresSourceState() {
        let store = InputStateStore()
        store.updateSource(.korean2Set)
        store.updateCapsLock(true)
        #expect(store.state == .capsLock)
        store.updateCapsLock(false)
        #expect(store.state == .korean)
    }

    @Test func sourceChangeWithinSameStateStillNotifies() {
        let store = InputStateStore()
        store.updateSource(.abc)
        var count = 0
        store.addObserver { _, _ in count += 1 }
        store.updateSource(.us)
        #expect(count == 1)
        #expect(store.state == .english)
    }

    @Test func sourceChangeWhileCapsLockKeepsCapsState() {
        let store = InputStateStore()
        store.updateCapsLock(true)
        store.updateSource(.korean2Set)
        #expect(store.state == .capsLock)
        #expect(store.snapshot.source == .korean2Set)
    }
}
