import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0086: a client that deactivates the server inside `insertText` (Fork,
/// 2026-10-10) must not be left with a mark of a composition that was already committed.
struct ActionDeliveryTests {
    /// A client and the session that writes to it, delivering the way the controller does.
    private final class Host {
        var session = ProbeSession()
        var committed = ""
        var marked = ""
        /// Deactivates the server inside the next commit, as Fork did.
        var deactivateOnNextCommit = false

        func apply(_ actions: [ProbeSession.Action]) {
            let ended = session.endedCompositions
            ActionDelivery.deliver(actions, compositionEnded: { session.endedCompositions != ended }) { action in
                switch action {
                case .mark(let text): marked = text
                case .commit(let text):
                    committed += text; marked = ""
                    if deactivateOnNextCommit {
                        deactivateOnNextCommit = false
                        // deactivateServer → commitComposition, inside the client's insertText.
                        apply(session.finish())
                    }
                }
            }
        }

        func type(_ keys: String) {
            for key in keys { apply(session.letter(key).actions) }
        }
    }

    /// "rks" + "k" commits 가 and marks 나. The deactivation inside the commit of 가
    /// already commits 나, so 나 is not marked again.
    @Test func reentrantDeactivationLeavesNoStaleMark() {
        let host = Host()
        host.type("rks")
        host.deactivateOnNextCommit = true
        host.type("k")
        #expect(host.committed == "가나")
        #expect(host.marked == "")
        #expect(host.session.pendingText == nil)
    }

    /// The next key starts a new composition next to the committed text, not in place of a stale mark.
    @Test func nextKeyComposesAfterTheCommittedText() {
        let host = Host()
        host.type("rks")
        host.deactivateOnNextCommit = true
        host.type("k")
        host.type("s")
        #expect(host.committed == "가나")
        #expect(host.marked == "ㄴ")
    }

    @Test func withoutReentrancyEveryActionIsDelivered() {
        let host = Host()
        host.type("rksk")
        #expect(host.committed == "가")
        #expect(host.marked == "나")
        // Backspace to an empty composition clears the mark with an empty one.
        host.apply(host.session.backspace().actions)
        host.apply(host.session.backspace().actions)
        #expect(host.marked == "")
    }

    /// A commit is the only copy of its text: it is delivered even after the composition ended.
    @Test func commitsAfterTheEndAreStillDelivered() {
        var delivered: [ProbeSession.Action] = []
        var ended = false
        let skipped = ActionDelivery.deliver([.commit("가"), .mark("나"), .commit("a")], compositionEnded: { ended }) {
            delivered.append($0)
            ended = true
        }
        #expect(delivered == [.commit("가"), .commit("a")])
        #expect(skipped == 1)
    }

    @Test func endedCompositionsCountsOnlyEndedCompositions() {
        var session = ProbeSession()
        _ = session.letter("r")
        _ = session.letter("k")
        _ = session.letter("s")
        _ = session.letter("k") // 가 committed, 나 still composing
        #expect(session.endedCompositions == 0)
        _ = session.finish()
        #expect(session.endedCompositions == 1)
        _ = session.finish() // nothing to commit
        #expect(session.endedCompositions == 1)
        session.observeClientMarkedText(true)
        _ = session.letter("r")
        session.reconcile(clientHasMarkedText: false)
        #expect(session.endedCompositions == 2)
    }
}
