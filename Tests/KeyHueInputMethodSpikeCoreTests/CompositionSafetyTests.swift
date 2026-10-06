import Testing
@testable import KeyHueInputMethodSpikeCore

/// 조합 중인 글자를 잃지 않는다: 조합에 쓰지 않는 입력은 모두 먼저 확정한 뒤 앱에 넘긴다.
/// 현재 동작을 고정하는 회귀 테스트(2026-10-03).
struct CompositionSafetyTests {
    private struct Client {
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

    private enum Key {
        static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76, forwardDelete: UInt16 = 117
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
        static let one: UInt16 = 18, period: UInt16 = 47, comma: UInt16 = 43, slash: UInt16 = 44
        static let s: UInt16 = 1, a: UInt16 = 0, c: UInt16 = 8, v: UInt16 = 9, z: UInt16 = 6, delete: UInt16 = 51
    }

    /// "dks" = 안(조합 중) 상태를 만든다.
    private func composing(_ mode: ProbeSession.Mode = .hangul) -> (ProbeSession, Client) {
        var session = ProbeSession()
        var client = Client()
        _ = session.select(mode)
        for key in (mode == .hangul ? "dks" : "a") { client.apply(session.letter(key).actions) }
        return (session, client)
    }

    // MARK: - 어떤 키를 먼저 확정하나

    nonisolated static let boundaryKeys: [UInt16] = [
        Key.returnKey, Key.tab, Key.space, Key.escape, Key.keypadEnter, Key.forwardDelete,
        Key.left, Key.right, Key.down, Key.up, Key.home, Key.end, Key.pageUp, Key.pageDown,
        Key.one, Key.period, Key.comma, Key.slash
    ]

    @Test(arguments: boundaryKeys)
    func boundaryAndCursorKeysCommitFirst(_ keyCode: UInt16) {
        for mode in [ProbeSession.Mode.hangul, .latin] {
            #expect(InputRouting.route(keyCode: keyCode, shift: false, capsLock: false, otherModifiers: false, mode: mode) == (keyCode == Key.space ? .commitSpace : .commitAndPass))
        }
    }

    @Test(arguments: [Key.s, Key.a, Key.c, Key.v, Key.z, Key.delete, Key.left, Key.returnKey, Key.space])
    func shortcutsCommitFirst(_ keyCode: UInt16) {
        // ⌘S, ⌘A, ⌘C, ⌘V, ⌘Z, ⌥⌫, ⌘←, ⌘Return, ⌃Space 등
        #expect(InputRouting.route(keyCode: keyCode, shift: false, capsLock: false, otherModifiers: true, mode: .hangul) == .commitAndPass)
        #expect(InputRouting.route(keyCode: keyCode, shift: true, capsLock: true, otherModifiers: true, mode: .latin) == .commitAndPass)
    }

    @Test func lettersComposeAndBackspaceEditsTheComposition() {
        #expect(InputRouting.route(keyCode: Key.s, shift: false, capsLock: false, otherModifiers: false, mode: .hangul) == .compose("s"))
        #expect(InputRouting.route(keyCode: 15, shift: true, capsLock: false, otherModifiers: false, mode: .hangul) == .compose("R"))
        #expect(InputRouting.route(keyCode: Key.delete, shift: false, capsLock: false, otherModifiers: false, mode: .hangul) == .backspace)
    }

    @Test func capsLockChangesOnlyLatinLetters() {
        #expect(InputRouting.route(keyCode: Key.a, shift: false, capsLock: true, otherModifiers: false, mode: .latin) == .compose("A"))
        #expect(InputRouting.route(keyCode: Key.a, shift: true, capsLock: true, otherModifiers: false, mode: .latin) == .compose("a"))
        // 한글은 Caps Lock으로 쌍자음을 만들지 않는다.
        #expect(InputRouting.route(keyCode: 15, shift: false, capsLock: true, otherModifiers: false, mode: .hangul) == .compose("r"))
    }

    // MARK: - 확정한 뒤 넘기면 글자가 남는다

    @Test(arguments: boundaryKeys)
    func lastSyllableSurvivesBoundaryAndCursorKeys(_ keyCode: UInt16) {
        var (session, client) = composing()
        let result = session.handle(InputRouting.route(keyCode: keyCode, shift: false, capsLock: false, otherModifiers: false, mode: session.mode))
        client.apply(result.actions)
        #expect(result.handled == (keyCode == Key.space))
        #expect(client.committed == (keyCode == Key.space ? "안 " : "안"))
        #expect(client.marked.isEmpty)
    }

    @Test func lastSyllableSurvivesShortcutsInBothModes() {
        for mode in [ProbeSession.Mode.hangul, .latin] {
            var (session, client) = composing(mode)
            let result = session.handle(InputRouting.route(keyCode: Key.s, shift: false, capsLock: false, otherModifiers: true, mode: mode))
            client.apply(result.actions)
            #expect(!result.handled)
            #expect(client.committed == (mode == .hangul ? "안" : "a"))
            #expect(client.marked.isEmpty)
        }
    }

    @Test func passingWithoutCompositionCommitsNothing() {
        var session = ProbeSession()
        let result = session.handle(.commitAndPass)
        #expect(result.actions.isEmpty)
        #expect(!result.handled)
    }

    @Test func spaceCommitsCompositionAndBoundaryInOneClientEdit() {
        for mode in [ProbeSession.Mode.hangul, .latin] {
            var (session, client) = composing(mode)
            let result = session.handle(.commitSpace)
            #expect(result.handled)
            #expect(result.actions == [.commit(mode == .hangul ? "안 " : "a ")])
            client.apply(result.actions)
            #expect(client.marked.isEmpty)
            #expect(session.finish().isEmpty)
            #expect(session.handle(.commitSpace).actions == [.commit(" ")])
        }
    }

    @Test func backspaceWithoutCompositionGoesToTheApp() {
        var session = ProbeSession()
        let result = session.handle(.backspace)
        #expect(result.actions.isEmpty)
        #expect(!result.handled)
    }

    @Test func modeSwitchCommitsBeforeTheNewMode() {
        var (session, client) = composing()
        client.apply(session.select(.latin))
        #expect(client.committed == "안")
        #expect(client.marked.isEmpty)
    }

    @Test func appRequestedCommitKeepsTheLastSyllable() {
        // commitComposition·deactivateServer는 finish()로 확정한다.
        var (session, client) = composing()
        client.apply(session.finish())
        #expect(client.committed == "안")
        client.apply(session.finish()) // 두 번 불려도 다시 넣지 않는다
        #expect(client.committed == "안")
    }

    // MARK: - 새 동작 (2026-10-03): 클릭, 앱이 먼저 확정/취소한 조합, 취소 요청

    @Test func mouseDownCommitsBeforeTheClickMovesTheCursor() {
        #expect(InputRouting.routeMouseDown() == .commitAndPass)
        var (session, client) = composing()
        let result = session.handle(InputRouting.routeMouseDown())
        client.apply(result.actions)
        #expect(!result.handled) // 클릭은 앱이 처리한다
        #expect(client.committed == "안")
    }

    @Test func compositionTheAppAlreadyFinishedIsNotInsertedTwice() {
        // 앱이 조합 중인 "안"을 스스로 확정했다(마우스·포커스 처리 등). 다음 키가 앞 글자를 다시 넣으면 "안안"이 된다.
        var (session, client) = composing()
        session.observeClientMarkedText(true)
        client.committed += client.marked; client.marked = "" // 앱 쪽 확정
        let dropped = session.reconcile(clientHasMarkedText: false)
        #expect(dropped)
        client.apply(session.letter("r").actions)
        client.apply(session.finish())
        #expect(client.committed == "안ㄱ")
    }

    @Test func compositionTheAppDiscardedDoesNotComeBack() {
        var (session, client) = composing()
        session.observeClientMarkedText(true)
        client.marked = "" // 앱 쪽에서 버림
        let dropped = session.reconcile(clientHasMarkedText: false)
        #expect(dropped)
        client.apply(session.letter("k").actions)
        client.apply(session.finish())
        #expect(client.committed == "ㅏ") // 버려진 "안"이 되살아나지 않는다
    }

    @Test func appsThatNeverReportMarkedTextKeepComposingNormally() {
        // markedRange를 알려 주지 않는 앱에서 "조합 없음"을 믿으면 키마다 조합이 끊긴다.
        var session = ProbeSession()
        var client = Client()
        for key in "dkssud" {
            let dropped = session.reconcile(clientHasMarkedText: false)
            #expect(!dropped)
            client.apply(session.letter(key).actions)
            session.observeClientMarkedText(false)
        }
        client.apply(session.finish())
        #expect(client.committed == "안녕")
    }

    @Test func matchingCompositionIsLeftAlone() {
        var (session, client) = composing()
        session.observeClientMarkedText(true)
        let kept = !session.reconcile(clientHasMarkedText: true)
        #expect(kept)
        client.apply(session.letter("s").actions)
        client.apply(session.finish())
        #expect(client.committed == "안ㄴ")
        var empty = ProbeSession()
        empty.observeClientMarkedText(true)
        let nothing = !empty.reconcile(clientHasMarkedText: false) // 조합이 없으면 할 일이 없다
        #expect(nothing)
    }

    @Test func cancelRequestCommitsInsteadOfLosingTheLastSyllable() {
        var (session, client) = composing()
        client.apply(session.cancelComposition())
        #expect(client.committed == "안")
        #expect(client.marked.isEmpty)
        let again = session.cancelComposition()
        #expect(again.isEmpty)
    }
}
