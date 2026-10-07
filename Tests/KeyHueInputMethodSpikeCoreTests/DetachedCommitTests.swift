import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0066: Ghostty sends the text committed during a key together with that key,
/// and the encoding of Tab and navigation keys drops the text. In Ghostty those keys
/// commit the composition after the key instead, so the last character is kept.
struct DetachedCommitTests {
    private enum Key {
        static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
        static let period: UInt16 = 47, one: UInt16 = 18, c: UInt16 = 8
    }
    private static let ghostty = "com.mitchellh.ghostty"

    @Test(arguments: [Key.tab, Key.left, Key.right, Key.up, Key.down, Key.home, Key.end, Key.pageUp, Key.pageDown, Key.forwardDelete])
    func ghosttyTabAndNavigationKeysCommitAfterTheKey(_ keyCode: UInt16) {
        #expect(DetachedCommit.applies(clientID: Self.ghostty, keyCode: keyCode, otherModifiers: false))
    }

    /// Text keys carry the committed text with their own; Return and Escape keep
    /// the committed text (the key itself is Ghostty's to handle).
    @Test(arguments: [Key.returnKey, Key.escape, Key.space, Key.period, Key.one])
    func otherKeysKeepTheUsualPath(_ keyCode: UInt16) {
        #expect(!DetachedCommit.applies(clientID: Self.ghostty, keyCode: keyCode, otherModifiers: false))
    }

    /// A shortcut (⌃C, ⌘→) must reach the app; it is never held back.
    @Test func shortcutsAreNeverHeldBack() {
        #expect(!DetachedCommit.applies(clientID: Self.ghostty, keyCode: Key.c, otherModifiers: true))
        #expect(!DetachedCommit.applies(clientID: Self.ghostty, keyCode: Key.right, otherModifiers: true))
    }

    /// Every other app keeps "commit, then pass the key" (ADR 0050).
    @Test(arguments: ["com.apple.TextEdit", "com.apple.Terminal", "com.googlecode.iterm2", ""])
    func otherAppsKeepTheUsualPath(_ clientID: String) {
        #expect(!DetachedCommit.applies(clientID: clientID, keyCode: Key.tab, otherModifiers: false))
    }

    @Test func anUnknownClientKeepsTheUsualPath() {
        #expect(!DetachedCommit.applies(clientID: nil, keyCode: Key.tab, otherModifiers: false))
    }

    // MARK: the held commit

    /// "rk" (가) then Tab: the syllable is held, not lost and not committed with the Tab.
    @Test func theCompositionIsHeldWhole() {
        var session = ProbeSession()
        _ = session.letter("r")
        _ = session.letter("k")
        var held = HeldCommit()
        held.hold(session.finish())
        #expect(session.pendingText == nil)
        #expect(held.take() == [.commit("가")])
        #expect(held.isEmpty)
    }

    /// English letters are committed as typed (ADR 0081): nothing is held and the
    /// Tab reaches the client with the letters.
    @Test func englishLeavesNothingToHold() {
        var session = ProbeSession()
        _ = session.select(.latin)
        _ = session.letter("r")
        _ = session.letter("k")
        #expect(session.pendingText == nil)
        #expect(session.finish().isEmpty)
    }

    /// The next key normally arrives after the held text was delivered. If it is
    /// faster, a text key delivers the held text first, so the order is kept.
    @Test func aFasterTextKeyDeliversTheHeldTextFirst() {
        var held = HeldCommit()
        held.hold([.commit("가")])
        let step = held.beforeKey(detached: false)
        #expect(step.deliver == [.commit("가")])
        #expect(!step.consumeKey)
        #expect(held.isEmpty)
    }

    /// A second Tab or arrow inside the same moment would drop the text again, so it
    /// stays behind the held text: the text is delivered, that key is not.
    @Test func aFasterDetachedKeyStaysBehindTheHeldText() {
        var held = HeldCommit()
        held.hold([.commit("가")])
        let step = held.beforeKey(detached: true)
        #expect(step.deliver.isEmpty)
        #expect(step.consumeKey)
        #expect(held.take() == [.commit("가")])
    }

    @Test func withNothingHeldKeysAreUntouched() {
        var held = HeldCommit()
        for detached in [true, false] {
            let step = held.beforeKey(detached: detached)
            #expect(step.deliver.isEmpty)
            #expect(!step.consumeKey)
        }
    }

    @Test func heldCommitsAccumulateInOrder() {
        var held = HeldCommit()
        held.hold([.commit("가")])
        held.hold([])
        held.hold([.commit("나")])
        #expect(held.take() == [.commit("가"), .commit("나")])
    }
}

/// ADR 0068: Ghostty sends a key the input method consumed unless text is
/// composing, so the correction shortcut reached the shell (⌥↩ as ESC Return)
/// and the shell's extra character threw the fix's Backspaces off by one.
struct ConsumedKeyTests {
    private static let ghostty = "com.mitchellh.ghostty"

    /// Nothing composing: a zero-width placeholder marks this key as composing
    /// and is cleared after it.
    @Test func ghosttyGetsAPlaceholderWhileTheKeyIsHandled() {
        let consumed = DetachedCommit.consume(clientID: Self.ghostty, committed: [])
        #expect(consumed.now == [.mark(DetachedCommit.placeholder)])
        #expect(consumed.after == [.mark("")])
        #expect(DetachedCommit.placeholder.utf16.count == 1)
    }

    /// Committed text is sent in place of the key, as before.
    @Test func ghosttyCommittedTextNeedsNoPlaceholder() {
        let consumed = DetachedCommit.consume(clientID: Self.ghostty, committed: [.commit("ㅇ")])
        #expect(consumed.now == [.commit("ㅇ")])
        #expect(consumed.after.isEmpty)
    }

    @Test(arguments: ["com.apple.TextEdit", "com.apple.Terminal", "com.googlecode.iterm2", ""])
    func otherAppsGetNoPlaceholder(_ clientID: String) {
        #expect(DetachedCommit.consume(clientID: clientID, committed: []).now.isEmpty)
        #expect(DetachedCommit.consume(clientID: clientID, committed: []).after.isEmpty)
    }
}
