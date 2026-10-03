import Testing
import KeyHueCore
@testable import KeyHueInputMethodSpikeCore

/// ProbeSession 엣지 케이스(2026-10-03): 조합 단계마다 Backspace, 조합 중 모드 전환, 글자가 아닌 키, 확정 중복.
struct SpikeEdgeProbeSessionTests {
    /// commit은 이전 marked text를 대체해 확정하고, mark는 조합만 바꾼다.
    private struct Client {
        var committed = ""
        var marked = ""
        var actions: [ProbeSession.Action] = []
        mutating func apply(_ new: [ProbeSession.Action]) {
            actions += new
            for action in new {
                switch action {
                case .commit(let text): committed += text; marked = ""
                case .mark(let text): marked = text
                }
            }
        }
    }

    // 한 글자(음절 또는 낱자)가 되는 키: 겹모음·겹받침·Shift를 섞었다.
    @Test(arguments: ["dhkfr", "Tnpqt", "Rhkd", "dmlf", "rkfg", "hk", "dO", "DKS"])
    func backspaceUndoesEveryCompositionStage(_ keys: String) throws {
        try #require(Dubeolsik.compose(keys: keys).units.count == 1)
        var session = ProbeSession()
        for (index, key) in keys.enumerated() {
            let expected = Dubeolsik.compose(keys: String(keys.prefix(index + 1))).text
            #expect(session.letter(key) == .init(actions: [.mark(expected)], handled: true), "\(keys) +\(key)")
        }
        for remaining in stride(from: keys.count - 1, through: 0, by: -1) {
            let expected = remaining == 0 ? "" : Dubeolsik.compose(keys: String(keys.prefix(remaining))).text
            #expect(session.backspace() == .init(actions: [.mark(expected)], handled: true), "\(keys) -> \(remaining)")
        }
        #expect(session.backspace() == .init(actions: [], handled: false))
        #expect(session.finish().isEmpty)
    }

    @Test func backspaceNeverTouchesCommittedTextAndUndoesOnlyTheMarkedLetter() {
        // 무작위 입력 뒤 Backspace를 끝까지: 마지막 글자의 키 수만큼만 처리하고 확정한 글자는 앱에 맡긴다
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzQWERTOPHKA")
        var seed: UInt64 = 7
        for _ in 0..<200 {
            var keys = ""
            for _ in 0..<12 {
                seed = seed &* 6364136223846793005 &+ 1
                keys.append(alphabet[Int((seed >> 32) % UInt64(alphabet.count))])
            }
            var session = ProbeSession()
            var client = Client()
            for key in keys { client.apply(session.letter(key).actions) }
            let committedBefore = client.committed
            let lastKeys = Dubeolsik.keys(for: client.marked)!
            var handled = 0
            while true {
                let result = session.backspace()
                guard result.handled else {
                    #expect(result.actions.isEmpty)
                    break
                }
                handled += 1
                client.apply(result.actions)
                let expected = Dubeolsik.compose(keys: String(lastKeys.dropLast(handled))).text
                #expect(client.marked == expected, "\(keys)")
                #expect(client.marked.count <= 1)
            }
            #expect(handled == lastKeys.count, "\(keys)")
            #expect(client.committed == committedBefore, "\(keys)")
            #expect(client.marked.isEmpty)
            #expect(!client.actions.contains(.commit("")), "\(keys)")
            #expect(session.finish().isEmpty)
        }
    }

    @Test func backspaceInsideACompoundFinalThenVowelMovesTheRemainingFinal() {
        var session = ProbeSession()
        for key in "rkqt" { _ = session.letter(key) }
        #expect(session.backspace().actions == [.mark("갑")])
        #expect(session.letter("k").actions == [.commit("가"), .mark("바")])
        #expect(session.finish() == [.commit("바")])
    }

    @Test func shiftedKeyIsKeptWhenAFinalMovesToTheNextSyllable() {
        // 있 + ㅏ = 이싸: 넘어간 ㅆ은 Shift+T 한 키다. 지우면 ㅅ이 아니라 ㅆ 전체가 남는다
        var session = ProbeSession()
        for key in "dlT" { _ = session.letter(key) }
        #expect(session.letter("k").actions == [.commit("이"), .mark("싸")])
        #expect(session.backspace().actions == [.mark("ㅆ")])
        #expect(session.backspace().actions == [.mark("")])
        #expect(!session.backspace().handled)
    }

    @Test func plainShiftLettersComposeAndUndoLikeLowercase() {
        var session = ProbeSession()
        var client = Client()
        for key in "DKSSUD" { client.apply(session.letter(key).actions) }
        #expect(client.committed == "안")
        #expect(client.marked == "녕")
        #expect(session.backspace().actions == [.mark("녀")])
        #expect(session.backspace().actions == [.mark("ㄴ")])
    }

    @Test func modeRoundTripDoesNotLetAVowelStealTheCommittedFinal() {
        var session = ProbeSession()
        for key in "rkqt" { _ = session.letter(key) }
        #expect(session.select(.latin) == [.commit("값")])
        #expect(session.select(.hangul).isEmpty)
        #expect(session.letter("k").actions == [.mark("ㅏ")])
        #expect(session.backspace().actions == [.mark("")])
        #expect(!session.backspace().handled)
    }

    @Test func modeSwitchInTheMiddleOfEveryStageCommitsExactlyThatStage() {
        for keys in ["r", "rh", "rhk", "rhkf", "rhkfr"] {
            var session = ProbeSession()
            var client = Client()
            for key in keys { client.apply(session.letter(key).actions) }
            client.apply(session.synchronize(inputSourceID: InputMethodIntegration.latinID) ?? [])
            #expect(client.committed == Dubeolsik.compose(keys: keys).text, "\(keys)")
            #expect(client.marked.isEmpty)
            #expect(session.mode == .latin)
            // 영문으로 넘어가도 한글 조합에 이어 붙지 않는다
            #expect(session.letter("k").actions == [.mark("k")])
            #expect(session.finish() == [.commit("k")])
        }
    }

    @Test func latinToHangulSwitchCommitsTheMarkedLetterBeforeComposing() {
        var session = ProbeSession()
        _ = session.select(.latin)
        _ = session.letter("x")
        #expect(session.select(.hangul) == [.commit("x")])
        #expect(session.letter("k").actions == [.mark("ㅏ")]) // x가 ㅌ이 되어 타가 되지 않는다
    }

    @Test(arguments: [ProbeSession.Mode.hangul, .latin])
    func nonLetterKeysCommitOnceAndPassThrough(_ mode: ProbeSession.Mode) {
        for key: Character in [" ", "1", ".", "\n", "\t", "é", "가", "ß"] {
            var session = ProbeSession()
            _ = session.select(mode)
            // 조합이 없으면 아무 동작 없이 넘긴다
            #expect(session.letter(key) == .init(actions: [], handled: false), "\(key)")
            _ = session.letter("r")
            let expected = mode == .hangul ? "ㄱ" : "r"
            #expect(session.letter(key) == .init(actions: [.commit(expected)], handled: false), "\(key)")
            #expect(session.letter(key) == .init(actions: [], handled: false), "\(key)")
            #expect(session.finish().isEmpty)
            #expect(!session.backspace().handled)
        }
    }

    @Test func vowelAfterABoundaryDoesNotJoinThePreviousSyllable() {
        var session = ProbeSession()
        var client = Client()
        for key in "rkr" { client.apply(session.letter(key).actions) }
        client.apply(session.letter(" ").actions)
        #expect(client.committed == "각")
        #expect(session.letter("k").actions == [.mark("ㅏ")]) // 가가 아니다
    }

    @Test func emptySessionOperationsAreNoOps() {
        var session = ProbeSession()
        #expect(session.backspace() == .init(actions: [], handled: false))
        #expect(session.finish().isEmpty)
        #expect(session.select(.latin).isEmpty)
        #expect(session.mode == .latin)
        #expect(session.select(.hangul).isEmpty)
        #expect(session.synchronize(inputSourceID: InputMethodIntegration.latinID) == [])
        #expect(session.mode == .latin)
    }

    @Test func retypingAfterErasingToEmptyDoesNotEmitAnEmptyCommit() {
        for mode in [ProbeSession.Mode.hangul, .latin] {
            var session = ProbeSession()
            _ = session.select(mode)
            _ = session.letter("a")
            #expect(session.backspace().actions == [.mark("")])
            let expected = mode == .hangul ? "ㅁ" : "b"
            #expect(session.letter(mode == .hangul ? "a" : "b").actions == [.mark(expected)])
        }
    }

    @Test func finishIsIdempotentAndResetsComposition() {
        var session = ProbeSession()
        for key in "rkf" { _ = session.letter(key) }
        #expect(session.finish() == [.commit("갈")])
        #expect(session.finish().isEmpty)
        // 확정 뒤의 모음은 새 글자(받침이 넘어가지 않는다), Backspace는 확정한 글자를 지우지 않는다
        #expect(!session.backspace().handled)
        #expect(session.letter("k").actions == [.mark("ㅏ")])
    }

    @Test(arguments: ["", " ", InputMethodIntegration.hangulID.uppercased(), InputMethodIntegration.hangulID + " ",
                      "com.apple.inputmethod.Korean.2SetKorean"])
    func nearMissSourceIDsAreNotOwned(_ id: String) {
        #expect(ProbeSession.Mode(inputSourceID: id) == nil)
        var session = ProbeSession()
        _ = session.letter("r")
        #expect(session.synchronize(inputSourceID: id) == nil)
        #expect(session.letter("k").actions == [.mark("가")]) // 조합이 이어진다
    }

    @Test func longHangulInputKeepsOnlyTheCurrentLetterMarked() {
        var session = ProbeSession()
        var client = Client()
        let keys = String(repeating: "dkssudgktpdy", count: 200)
        for key in keys {
            client.apply(session.letter(key).actions)
            #expect(client.marked.count == 1)
        }
        #expect(client.marked == "요")
        // Backspace는 마지막 글자 하나만 되돌린다(앞 글자 키를 버퍼에 쌓지 않는다)
        #expect(session.backspace().actions == [.mark("ㅇ")])
        #expect(session.backspace().actions == [.mark("")])
        #expect(!session.backspace().handled)
        client.apply(session.finish())
        #expect(client.committed == String(String(repeating: "안녕하세요", count: 200).dropLast()))
    }
}
