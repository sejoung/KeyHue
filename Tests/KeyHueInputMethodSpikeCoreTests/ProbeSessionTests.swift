import Testing
import KeyHueCore
@testable import KeyHueInputMethodSpikeCore

struct ProbeSessionTests {
    @Test(arguments: [InputMethodIntegration.latinID, InputMethodIntegration.abcID])
    func sourceChangeWithoutNextEventCommitsOnlyTheVerifiedMarkOnce(_ id: String) {
        var session = ProbeSession()
        var client = TestClient()
        for key in "dkssud" { client.apply(session.letter(key).actions) }
        #expect(client.committed == "안")
        #expect(session.pendingText == "녕")
        client.apply(session.finishAfterSourceChange(inputSourceID: id, verifiedMarkedText: client.marked))
        #expect(client.committed == "안녕")
        #expect(client.marked.isEmpty)
        #expect(session.pendingText == nil)
        #expect(session.finishAfterSourceChange(inputSourceID: id, verifiedMarkedText: "녕").isEmpty)
        #expect(session.finish().isEmpty) // A later deactivate must not insert again.
        #expect(session.mode == .hangul) // Notification does not choose the engine mode.
    }

    @Test(arguments: [Optional<String>.none, "", InputMethodIntegration.hangulID])
    func unavailableOrSameSourceNotificationKeepsComposition(_ id: String?) {
        var session = ProbeSession()
        for key in "rhk" { _ = session.letter(key) }
        #expect(session.finishAfterSourceChange(inputSourceID: id, verifiedMarkedText: "과").isEmpty)
        #expect(session.letter("r").actions == [.mark("곽")])
    }

    @Test(arguments: [Optional<String>.none, "other text", ""])
    func unverifiableMarkIsNeverReplacedAfterSourceChange(_ text: String?) {
        var session = ProbeSession()
        for key in "dks" { _ = session.letter(key) }
        #expect(session.finishAfterSourceChange(inputSourceID: InputMethodIntegration.latinID, verifiedMarkedText: text).isEmpty)
        #expect(session.pendingText == "안")
    }

    @Test func latinTextSurvivesForeignSourceWithoutDuplication() {
        var session = ProbeSession()
        var client = TestClient()
        _ = session.select(.latin)
        for key in "abc" { client.apply(session.letter(key).actions) }
        client.apply(session.finishAfterSourceChange(inputSourceID: InputMethodIntegration.systemHangulID, verifiedMarkedText: client.marked))
        #expect(client.committed == "abc")
        #expect(client.marked.isEmpty)
        #expect(session.synchronize(inputSourceID: InputMethodIntegration.hangulID)?.isEmpty == true)
        #expect(session.letter("r").actions == [.mark("ㄱ")])
    }

    @Test func returningFromLatinWithoutModeCallbackUsesHangulOnFirstKey() {
        var session = ProbeSession()
        var client = TestClient()
        _ = session.select(.latin)
        // No activation/setValue in between: only TIS reports the selected source.
        for key in "dkssud" {
            client.apply(session.synchronize(inputSourceID: InputMethodIntegration.hangulID) ?? [])
            client.apply(session.letter(key).actions)
        }
        client.apply(session.finish())
        #expect(session.mode == .hangul)
        #expect(client.committed == "안녕")
        #expect(client.marked.isEmpty)
    }

    // Matches macOS 2-Set Korean (checked 2026-10-03): no compound jamo without a vowel.
    @Test func consonantPairWithoutAVowelIsCommittedSeparately() {
        var session = ProbeSession()
        var client = TestClient()
        for key in "qt" { client.apply(session.letter(key).actions) }
        client.apply(session.finish())
        #expect(client.committed == "ㅂㅅ")
        #expect(client.marked.isEmpty)
    }

    @Test func repeatedSameModeCallbacksDoNotSplitPendingSyllable() {
        var session = ProbeSession()
        var client = TestClient()
        for key in "rhkrt" {
            client.apply(session.letter(key).actions)
            #expect(session.select(.hangul).isEmpty)
            #expect(session.synchronize(inputSourceID: InputMethodIntegration.hangulID)?.isEmpty == true)
        }
        client.apply(session.finish())
        #expect(client.committed == "곿")
        #expect(client.marked.isEmpty)
    }

    @Test func missingCallbacksInBothDirectionsKeepPendingTextOnce() {
        var session = ProbeSession()
        var client = TestClient()
        for key in "dkssud" { client.apply(session.letter(key).actions) }
        client.apply(session.synchronize(inputSourceID: InputMethodIntegration.latinID) ?? [])
        for key in "hello" { client.apply(session.letter(key).actions) }
        client.apply(session.synchronize(inputSourceID: InputMethodIntegration.hangulID) ?? [])
        for key in "rk" { client.apply(session.letter(key).actions) }
        client.apply(session.finish())
        #expect(client.committed == "안녕hello가")
        #expect(session.finish().isEmpty)
    }

    @Test func syncBeforeBackspaceUsesNewModeAndCommitsOnlyOldPendingText() {
        var session = ProbeSession()
        _ = session.select(.latin)
        for key in "hello" { _ = session.letter(key) }
        // English letters were committed as typed: nothing is left to commit again.
        #expect(session.synchronize(inputSourceID: InputMethodIntegration.hangulID) == [])
        #expect(!session.backspace().handled)
        #expect(session.letter("r").actions == [.mark("ㄱ")])
    }

    @Test(arguments: [Optional<String>.none, "com.apple.keylayout.ABC", "unrelated.Hangul", "io.github.sejoung.keyhue.inputmethod.spike"])
    func unknownOrForeignSourceDoesNotMutateTheSession(_ id: String?) {
        var session = ProbeSession()
        _ = session.letter("r")
        #expect(session.synchronize(inputSourceID: id) == nil)
        #expect(session.mode == .hangul)
        #expect(session.finish() == [.commit("ㄱ")])
    }

    @Test func finalMovesToNextSyllableAndOnlyCurrentSyllableRemainsMarked() {
        var session = ProbeSession()
        let expected: [[ProbeSession.Action]] = [
            [.mark("ㄱ")], [.mark("가")], [.mark("각")], [.commit("가"), .mark("가")]
        ]
        for (key, actions) in zip("rkrk", expected) {
            #expect(session.letter(key) == .init(actions: actions, handled: true))
        }
        #expect(session.backspace().actions == [.mark("ㄱ")])
        #expect(session.backspace().actions == [.mark("")])
        // 앞의 확정된 '가'를 삭제하는 다음 Backspace는 앱에 맡긴다.
        #expect(!session.backspace().handled)
        #expect(session.finish().isEmpty)
    }

    @Test func compoundVowelAndFinalUndoOneKeyAtATime() {
        var session = ProbeSession()
        for key in "rhkrt" { _ = session.letter(key) }
        #expect(session.backspace().actions == [.mark("곽")])
        #expect(session.backspace().actions == [.mark("과")])
        #expect(session.backspace().actions == [.mark("고")])
    }

    @Test func changingModeCommitsOldCompositionOnce() {
        var session = ProbeSession()
        for key in "dkssud" { _ = session.letter(key) }
        #expect(session.select(.latin) == [.commit("녕")])
        #expect(session.finish().isEmpty)
        #expect(session.letter("A").actions == [.commit("A")])
        #expect(!session.backspace().handled)
    }

    /// ADR 0081: an English letter is complete as typed. Nothing stays composing,
    /// so a terminal never spends the next Return on finishing a composition.
    @Test func latinCommitsEveryLetterAtOnceAndNeverMarks() {
        var session = ProbeSession()
        _ = session.select(.latin)
        var client = TestClient()
        for key in "hello world again" {
            let result = session.letter(key)
            client.apply(result.actions)
            #expect(client.marked.isEmpty)
            #expect(session.pendingText == nil)
            if result.handled {
                #expect(result.actions == [.commit(String(key))])
            } else {
                #expect(result.actions.isEmpty)
                client.committed.append(key) // Space is handled once by the client.
            }
        }
        #expect(client.committed == "hello world again")
        #expect(session.finish().isEmpty)
    }

    @Test func latinBackspaceAlwaysGoesToTheApp() {
        var session = ProbeSession()
        _ = session.select(.latin)
        #expect(session.letter("a").actions == [.commit("a")])
        #expect(session.letter("b").actions == [.commit("b")])
        #expect(!session.backspace().handled)
        #expect(session.finish().isEmpty)
    }

    @Test func boundedBufferCommitsWithoutDroppingLongInput() {
        var session = ProbeSession()
        _ = session.select(.latin)
        var committed = ""
        for key in String(repeating: "a", count: 130) {
            for case .commit(let text) in session.letter(key).actions { committed += text }
        }
        for case .commit(let text) in session.finish() { committed += text }
        #expect(committed == String(repeating: "a", count: 130))
    }

    @Test func sessionsHaveIndependentBuffersAndModes() {
        var first = ProbeSession()
        var second = ProbeSession()
        _ = first.letter("r")
        _ = second.select(.latin)
        #expect(second.letter("b").actions == [.commit("b")])
        #expect(first.finish() == [.commit("ㄱ")])
        #expect(second.finish().isEmpty)
    }

    @Test func unsupportedInputFinishesAndPassesThrough() {
        var session = ProbeSession()
        _ = session.letter("r")
        #expect(session.letter("1") == .init(actions: [.commit("ㄱ")], handled: false))
        #expect(session.finish().isEmpty)
    }

    @Test func compoundFinalSplitsAndBackspaceDoesNotRestoreCommittedPrefix() {
        var session = ProbeSession()
        for key in "rkqt" { _ = session.letter(key) }
        #expect(session.letter("k").actions == [.commit("갑"), .mark("사")])
        #expect(session.backspace().actions == [.mark("ㅅ")])
        #expect(session.backspace().actions == [.mark("")])
        #expect(!session.backspace().handled)
    }

    @Test func looseJamoAndShiftedKeysCommitWithoutExtendingMarkedRange() {
        var session = ProbeSession()
        #expect(session.letter("R").actions == [.mark("ㄲ")])
        #expect(session.letter("k").actions == [.mark("까")])
        #expect(session.letter("E").actions == [.commit("까"), .mark("ㄸ")])
        #expect(session.letter("H").actions == [.mark("또")])
        #expect(session.letter("K").actions == [.mark("똬")])
        #expect(session.backspace().actions == [.mark("또")])
        #expect(session.letter("i").actions == [.commit("또"), .mark("ㅑ")])
        #expect(session.letter("o").actions == [.commit("ㅑ"), .mark("ㅐ")])
    }

    @Test func incrementalClientEditsMatchBatchComposition() {
        // 클라이언트처럼 commit은 이전 marked text를 대체하고 mark는 조합만 갱신한다.
        // 단어·낱자·Shift·겹모음·겹받침을 섞어 확정 시 글자 유실/중복을 검사한다.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzQWERTOPHKA")
        var seed: UInt64 = 42
        var samples = ["dkssudgktpdy", "rhkrtk", "rkqtk", "rrrkkkk", "RkEHKio", String(repeating: "dkssud", count: 50)]
        for _ in 0..<300 {
            var keys = ""
            for _ in 0..<40 {
                seed = seed &* 6364136223846793005 &+ 1
                keys.append(alphabet[Int((seed >> 32) % UInt64(alphabet.count))])
            }
            samples.append(keys)
        }
        for keys in samples {
            var session = ProbeSession()
            var client = TestClient()
            for key in keys {
                let result = session.letter(key)
                #expect(result.handled)
                client.apply(result.actions)
                #expect(client.marked.count == 1)
            }
            client.apply(session.finish())
            #expect(client.marked.isEmpty)
            #expect(client.committed == Dubeolsik.compose(keys: keys).text)
            #expect(session.finish().isEmpty)
        }
    }

    /// ADR 0081 across modes: random runs of Korean and English (Shift and Caps
    /// letters too), separated by Space or a mode change without a callback. English
    /// never leaves a composition, and every run reaches the client exactly once.
    @Test func mixedModesNeverComposeEnglishAndKeepEveryRunOnce() {
        let letters = Array("abcdefghijklmnopqrstuvwxyzQWERTOPHKA")
        var seed: UInt64 = 81
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<300 {
            var session = ProbeSession()
            var client = TestClient()
            var expected = ""
            // Runs of one mode with nothing between them compose as one (rk + s → 간).
            var run: (mode: ProbeSession.Mode, keys: String)?
            func flush() {
                guard let current = run else { return }
                expected += current.mode == .hangul ? Dubeolsik.compose(keys: current.keys).text : current.keys
                run = nil
            }
            for _ in 0..<(1 + next(6)) {
                let mode: ProbeSession.Mode = next(2) == 0 ? .hangul : .latin
                if run?.mode != mode { flush() }
                client.apply(session.synchronize(inputSourceID: mode == .hangul ? InputMethodIntegration.hangulID : InputMethodIntegration.latinID) ?? [])
                for _ in 0..<(1 + next(8)) {
                    let key = letters[next(letters.count)]
                    run = (mode, (run?.keys ?? "") + String(key))
                    let result = session.letter(key)
                    #expect(result.handled)
                    client.apply(result.actions)
                    if mode == .latin {
                        #expect(session.pendingText == nil && client.marked.isEmpty)
                    }
                }
                if next(2) == 0 {
                    let space = session.handle(.commitSpace)
                    #expect(space.handled)
                    client.apply(space.actions)
                    flush()
                    expected += " "
                }
            }
            flush()
            client.apply(session.finish())
            #expect(client.marked.isEmpty)
            #expect(client.committed == expected)
            #expect(session.finish().isEmpty)
        }
    }

    @Test func boundariesAndModeChangesFinishOnlyPendingTextOnce() {
        var session = ProbeSession()
        var client = TestClient()
        for key in "dkssud" { client.apply(session.letter(key).actions) }
        #expect(client.committed == "안")
        #expect(client.marked == "녕")
        let result = session.letter(" ")
        #expect(!result.handled)
        client.apply(result.actions)
        #expect(client.committed == "안녕")
        #expect(client.marked.isEmpty)
        #expect(session.select(.latin).isEmpty)
        #expect(session.finish().isEmpty)
    }

    private struct TestClient {
        var committed = ""
        var marked = ""
        mutating func apply(_ actions: [ProbeSession.Action]) {
            for action in actions {
                switch action {
                case .commit(let text): committed += text; marked = ""
                case .mark(let text): marked = text
                }
            }
        }
    }
}
