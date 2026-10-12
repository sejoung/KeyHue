import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0090: ChatGPT (editing a message, 2026-10-12) deactivated the server inside
/// every `insertText` and activated it again with the next key.
struct ReentrantDeactivationTests {
    /// A client and the controller's handling of deactivation, activation and the kept-composition timer.
    private final class Host {
        var session = ProbeSession()
        var committed = ""
        var marked = ""
        var active = true
        /// Deactivates the server inside the next commit, as ChatGPT did.
        var deactivateOnNextCommit = false
        private var depth = 0
        private(set) var kept = false

        func apply(_ actions: [ProbeSession.Action]) {
            let ended = session.endedCompositions
            depth += 1
            defer { depth -= 1 }
            ActionDelivery.deliver(actions, compositionEnded: { session.endedCompositions != ended }) { action in
                switch action {
                case .mark(let text):
                    marked = text
                    session.observeClientMarkedText(!text.isEmpty)
                case .commit(let text):
                    committed += text; marked = ""
                    if deactivateOnNextCommit {
                        deactivateOnNextCommit = false
                        deactivate()
                    }
                }
            }
        }

        func deactivate() {
            active = false
            if ReentrantDeactivation.keepsComposition(duringDelivery: depth > 0, composing: session.pendingText != nil) {
                kept = true
            } else {
                apply(session.finish())
            }
        }

        func activate() {
            active = true
            if kept {
                kept = false
                session.reconcile(clientHasMarkedText: !marked.isEmpty)
            }
        }

        /// The client opens the context again before each key, as ChatGPT did.
        func type(_ keys: String) {
            for key in keys {
                if !active { activate() }
                apply(session.letter(key).actions)
            }
        }

        /// `commitDelay` passed with the client still closed.
        func timerFires() {
            guard kept, !active else { return }
            kept = false
            apply(session.finish())
        }
    }

    /// "rks" + "k" commits 가 and marks 나. The deactivation inside the commit of 가
    /// keeps 나, so the next ㄴ makes 난 instead of 나ㄴ.
    @Test func deactivationInsideAnEditKeepsTheComposition() {
        let host = Host()
        host.type("rks")
        host.deactivateOnNextCommit = true
        host.type("k")
        #expect(host.committed == "가")
        #expect(host.marked == "나")
        #expect(host.session.pendingText == "나")
        host.type("s")
        #expect(host.committed == "가")
        #expect(host.marked == "난")
    }

    @Test func everySyllableSurvivesADeactivationInEveryCommit() {
        let host = Host()
        for key in "gksrmfdmf" { // 한글을
            host.deactivateOnNextCommit = true
            host.type(String(key))
        }
        host.apply(host.session.finish())
        #expect(host.committed == "한글을")
    }

    @Test func aKeptCompositionIsCommittedWhenTheClientStaysClosed() {
        let host = Host()
        host.type("rks")
        host.deactivateOnNextCommit = true
        host.type("k")
        host.timerFires()
        #expect(host.committed == "가나")
        #expect(host.marked == "")
        #expect(host.session.pendingText == nil)
    }

    /// Focus moved to another field while closed: the client finished the mark itself,
    /// so the session drops it instead of writing it a second time.
    @Test func aCompositionTheClientFinishedIsDroppedOnActivation() {
        let host = Host()
        host.type("rks")
        host.deactivateOnNextCommit = true
        host.type("k")
        host.committed += host.marked; host.marked = ""
        host.activate()
        #expect(host.session.pendingText == nil)
        host.type("r")
        #expect(host.committed == "가나")
        #expect(host.marked == "ㄱ")
    }

    @Test func aDeactivationOutsideAnEditCommits() {
        let host = Host()
        host.type("rk")
        host.deactivate()
        #expect(host.committed == "가")
        #expect(!host.kept)
        #expect(!ReentrantDeactivation.keepsComposition(duringDelivery: false, composing: true))
        #expect(!ReentrantDeactivation.keepsComposition(duringDelivery: true, composing: false))
    }
}
