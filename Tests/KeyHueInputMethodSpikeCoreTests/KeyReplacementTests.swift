import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0067: in a terminal the input method erases the word with Backspace keys
/// and inserts the replacement; it never sees the terminal's text.
@Suite("Key replacement")
struct KeyReplacementTests {
    /// One Backspace per character the terminal shows. Precomposed syllables and
    /// compatibility jamo are one character each.
    @Test func aCorrectionErasesTheOriginalAndInsertsTheReplacement() {
        let toHangul = KeyReplacement(correcting: CorrectionEdit(location: 0, original: "dkssud ", replacement: "안녕 "))
        #expect(toHangul == KeyReplacement(erase: 7, insert: "안녕 "))
        let toLatin = KeyReplacement(correcting: CorrectionEdit(location: 0, original: "ㅗ디ㅣㅐ", replacement: "hello"))
        #expect(toLatin == KeyReplacement(erase: 4, insert: "hello"))
    }

    @Test func anUndoErasesTheReplacementAndInsertsTheOriginal() {
        let undo = KeyReplacement(undoing: CorrectionEdit(location: 0, original: "dkssud ", replacement: "안녕 "))
        #expect(undo == KeyReplacement(erase: 3, insert: "dkssud "))
    }

    /// Only the input method's own Backspaces pass untouched; the insert follows the last one.
    @Test func postedBackspacesAreRecognizedUntilTheLastOne() {
        var posted = PostedBackspaces()
        #expect(posted.arrived(isBackspace: true) == .notOurs)
        posted.post(2)
        #expect(posted.arrived(isBackspace: true) == .passThrough)
        #expect(posted.arrived(isBackspace: true) == .passThroughLast)
        #expect(posted.arrived(isBackspace: true) == .notOurs)
    }

    /// The user's own key between ours is not taken for one of ours.
    @Test func otherKeysAreNeverOurs() {
        var posted = PostedBackspaces()
        posted.post(1)
        #expect(posted.arrived(isBackspace: false) == .notOurs)
        #expect(posted.arrived(isBackspace: true) == .passThroughLast)
    }

    /// Keys that never arrived (focus moved, posting refused) are forgotten so a
    /// later real Backspace is not swallowed.
    @Test func abandonedBackspacesAreForgotten() {
        var posted = PostedBackspaces()
        posted.post(3)
        #expect(posted.arrived(isBackspace: true) == .passThrough)
        #expect(posted.abandon() == 1)
        #expect(posted.arrived(isBackspace: true) == .notOurs)
    }
}
