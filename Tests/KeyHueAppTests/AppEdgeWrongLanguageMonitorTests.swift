import AppKit
import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// 백그라운드 읽기 횟수를 세는 카운터(@Sendable 클로저에서 쓴다).
final class AppEdgeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
@Suite("Wrong language monitor edge cases")
struct AppEdgeWrongLanguageMonitorTests {
    static let modelURL = WrongLanguageMonitorTests.modelURL
    static let abc = InputSourceInfo.abc.id
    static let korean = InputSourceInfo.korean2Set.id

    private static let codes: [Character: Int64] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49
    ]

    private func type(
        _ text: String, sourceID: String?, into monitor: WrongLanguageMonitor,
        capsLock: Bool = false, otherModifiers: Bool = false
    ) {
        for char in text {
            monitor.key(KeyboardMonitor.KeyDown(
                keyCode: Self.codes[Character(char.lowercased())]!, isAutoRepeat: false,
                shift: char.isUppercase, otherModifiers: otherModifiers, capsLock: capsLock
            ), sourceID: sourceID)
        }
    }

    /// 단어 끝에서만 판정하는(접두사 없음) 준비된 모니터와 받은 경고 목록.
    private func readyMonitor() async -> (WrongLanguageMonitor, () -> [MistypeVerdict]) {
        let monitor = WrongLanguageMonitor(modelURL: Self.modelURL, lexicon: { WordListLexicon(["hello", "world"]) }, prefixWords: { [] })
        await monitor.prepare()
        monitor.setEnabled(true)
        final class Box { var verdicts: [MistypeVerdict] = [] }
        let box = Box()
        monitor.onWarning = { verdict, _ in box.verdicts.append(verdict) }
        return (monitor, { box.verdicts })
    }

    @Test func disablingMidWordDiscardsTheWord() async {
        let (monitor, verdicts) = await readyMonitor()
        type("dkssudgktpdy", sourceID: Self.abc, into: monitor)
        monitor.setEnabled(false)
        monitor.setEnabled(true)
        type(" ", sourceID: Self.abc, into: monitor)
        #expect(verdicts().isEmpty)
        // 다음 단어는 다시 본다
        type("dkssud ", sourceID: Self.abc, into: monitor)
        #expect(verdicts() == [.meantHangul("안녕")])
    }

    @Test func keysTypedWhileDisabledAreNeverCollected() async {
        let (monitor, verdicts) = await readyMonitor()
        monitor.setEnabled(false)
        type("dkssudgktpdy", sourceID: Self.abc, into: monitor)
        monitor.setEnabled(true)
        type(" ", sourceID: Self.abc, into: monitor)
        #expect(verdicts().isEmpty)
    }

    @Test func resetMidWordDiscardsTheWordButNotTheNextOne() async {
        // 마우스 클릭·앱 전환: 커서가 움직였을 수 있다.
        let (monitor, verdicts) = await readyMonitor()
        type("dkssudgktpdy", sourceID: Self.abc, into: monitor)
        monitor.reset()
        type(" ", sourceID: Self.abc, into: monitor)
        #expect(verdicts().isEmpty)
        type("dkssud ", sourceID: Self.abc, into: monitor)
        #expect(verdicts() == [.meantHangul("안녕")])
        monitor.reset()
        monitor.reset() // 비어 있을 때 다시 불러도 괜찮다
        type("hello ", sourceID: Self.korean, into: monitor)
        #expect(verdicts().last == .meantLatin("hello"))
    }

    @Test func capsLockKeysAreNotJudged() async {
        let (monitor, verdicts) = await readyMonitor()
        type("dkssudgktpdy ", sourceID: Self.abc, into: monitor, capsLock: true)
        #expect(verdicts().isEmpty)
        // Caps Lock을 끈 뒤 새 단어는 본다
        type("dkssud ", sourceID: Self.abc, into: monitor)
        #expect(verdicts() == [.meantHangul("안녕")])
    }

    @Test func capsLockInTheMiddleOfAWordDiscardsTheWholeWord() async {
        let (monitor, verdicts) = await readyMonitor()
        type("dkss", sourceID: Self.abc, into: monitor)
        type("u", sourceID: Self.abc, into: monitor, capsLock: true)
        type("d ", sourceID: Self.abc, into: monitor)
        #expect(verdicts().isEmpty)
    }

    @Test func unknownOrUnsupportedSourceMidWordDiscardsTheWord() async {
        let (monitor, verdicts) = await readyMonitor()
        for other: String? in [nil, "com.apple.keylayout.Dvorak"] {
            type("dkss", sourceID: Self.abc, into: monitor)
            type("u", sourceID: other, into: monitor)
            type("d ", sourceID: Self.abc, into: monitor)
        }
        #expect(verdicts().isEmpty)
    }

    @Test func switchingModeMidWordDiscardsTheWord() async {
        // "API를"처럼 단어 중간에 입력 모드를 바꾼 것은 잘못 친 단어가 아니다.
        let (monitor, verdicts) = await readyMonitor()
        type("dkss", sourceID: Self.abc, into: monitor)
        type("ud ", sourceID: Self.korean, into: monitor)
        #expect(verdicts().isEmpty)
    }

    @Test func shortcutMidWordDiscardsUntilTheNextWord() async {
        let (monitor, verdicts) = await readyMonitor()
        type("dkss", sourceID: Self.abc, into: monitor)
        type("v", sourceID: Self.abc, into: monitor, otherModifiers: true) // ⌘V
        type("udgktpdy ", sourceID: Self.abc, into: monitor)
        #expect(verdicts().isEmpty)
        type("dkssud ", sourceID: Self.abc, into: monitor)
        #expect(verdicts() == [.meantHangul("안녕")])
    }

    @Test func notReadyMonitorIgnoresKeysEvenWhenEnabled() {
        // 켜자마자(모델을 읽는 중) 친 키는 판정하지 않고, 멈추지도 않는다.
        let monitor = WrongLanguageMonitor(modelURL: nil, lexicon: { WordListLexicon([]) })
        var warned = false
        monitor.onWarning = { _, _ in warned = true }
        monitor.setEnabled(true)
        #expect(monitor.isEnabled)
        #expect(!monitor.isReady)
        type("dkssudgktpdy ", sourceID: Self.abc, into: monitor)
        monitor.reset()
        #expect(!warned)
    }

    @Test(arguments: [
        "garbage", "", "\u{FFFD}\u{0000}",
        "# KeyHue hangul syllable model v1\n",            // 머리글만 있는 빈 모델
        "# KeyHue hangul syllable model v1\n가\t",       // 잘린 파일
        "# KeyHue hangul syllable model v2\n가\t10\n"    // 모르는 형식 버전
    ])
    func malformedModelFileIsReportedMissing(_ contents: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hangul-syllables.tsv")
        try Data(contents.utf8).write(to: url)
        let monitor = WrongLanguageMonitor(modelURL: url, lexicon: { WordListLexicon([]) }, prefixWords: { [] })
        await monitor.prepare()
        #expect(monitor.isModelMissing)
        #expect(!monitor.isReady)
    }

    @Test func modelPathThatDoesNotExistIsReportedMissing() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueTests-missing-\(UUID().uuidString).tsv")
        let monitor = WrongLanguageMonitor(modelURL: url, lexicon: { WordListLexicon([]) }, prefixWords: { [] })
        await monitor.prepare()
        #expect(monitor.isModelMissing)
        #expect(!monitor.isReady)
    }

    @Test func missingModelIsNotRetriedOnEveryEnable() async {
        let lexiconReads = AppEdgeCounter()
        let monitor = WrongLanguageMonitor(modelURL: nil, lexicon: { lexiconReads.increment(); return WordListLexicon([]) })
        await monitor.prepare()
        await monitor.prepare()
        #expect(monitor.isModelMissing)
        #expect(lexiconReads.value == 0)
    }

    @Test func concurrentPreparesLoadTheModelOnce() async {
        // 설정을 빠르게 켰다 껐다 하거나 wake와 겹쳐 prepare가 동시에 불려도 한 번만 읽는다.
        let prefixReads = AppEdgeCounter(), lexiconReads = AppEdgeCounter()
        let monitor = WrongLanguageMonitor(
            modelURL: Self.modelURL,
            lexicon: { lexiconReads.increment(); return WordListLexicon(["hello"]) },
            prefixWords: { prefixReads.increment(); return ["hello"] }
        )
        async let first: Void = monitor.prepare()
        async let second: Void = monitor.prepare()
        async let third: Void = monitor.prepare()
        _ = await (first, second, third)
        await monitor.prepare() // 이미 읽은 뒤에는 바로 돌아온다
        #expect(monitor.isReady)
        #expect(!monitor.isModelMissing)
        #expect(prefixReads.value == 1)
        #expect(lexiconReads.value == 1)
    }

    @Test func toastKeepsAWordOfExactlyTheLimitWhole() {
        let toast = WrongLanguageToast(mask: NSImage(size: NSSize(width: 20, height: 20)), scheduler: FakeScheduler())
        defer { toast.hideNow() }
        let exact = String(repeating: "가", count: 24)
        toast.show(word: exact, sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.word == exact + "?")
        // 치는 중 경고("…")가 붙어 한도를 넘으면 잘라서 "…" 하나만 남긴다
        toast.show(word: exact + "…", sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.word == exact + "…?")
        toast.show(word: "", sourceName: "", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.word == "?")
        #expect(toast.isShowing)
    }

    @Test func newWarningRestartsTheToastTimer() {
        let clock = FakeScheduler()
        let toast = WrongLanguageToast(mask: NSImage(size: NSSize(width: 20, height: 20)), scheduler: clock)
        defer { toast.hideNow() }
        toast.show(word: "안녕", sourceName: "2-Set Korean", color: .defaultCapsLock, on: NSScreen.main)
        clock.advance(by: WrongLanguageToast.holdDuration - 0.1)
        toast.show(word: "hello", sourceName: "ABC", color: .defaultCapsLock, on: NSScreen.main)
        #expect(toast.word == "hello?")
        clock.advance(by: 0.2) // 첫 번째 숨김 예약 시각이 지나도 새 경고는 남아 있다
        #expect(toast.isShowing)
        clock.advance(by: WrongLanguageToast.holdDuration)
        #expect(!toast.isShowing)
    }
}
