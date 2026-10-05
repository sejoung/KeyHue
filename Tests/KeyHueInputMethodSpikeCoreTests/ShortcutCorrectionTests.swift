import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0068: the user asks for a fix with a shortcut. Whatever they point at is
/// re-read as typed on the other layout: no detector, no word tracking that can
/// silently drop a word.
@Suite("Shortcut correction")
struct ShortcutCorrectionTests {
    // MARK: conversion

    @Test func latinTextBecomesHangulAndHangulBecomesLatin() {
        #expect(LayoutConversion.convert("dkssudgktpdy", to: .hangul) == "안녕하세요")
        #expect(LayoutConversion.convert("ㅗ디ㅣㅐ", to: .latin) == "hello")
        #expect(LayoutConversion.convert("안녕", to: .latin) == "dkssud")
    }

    /// Asked for, so always converted: real English becomes jamo too.
    @Test func theDetectorIsNotAsked() {
        #expect(LayoutConversion.convert("hello", to: .hangul) == "ㅗ디ㅣㅐ")
    }

    /// The target is the other script of the last letter.
    @Test func theTargetIsTheOtherScriptOfTheLastLetter() {
        #expect(LayoutConversion.target(of: "dkssud") == .hangul)
        #expect(LayoutConversion.target(of: "ㅗ디ㅣㅐ") == .latin)
        #expect(LayoutConversion.target(of: "안녕dks") == .hangul)
        #expect(LayoutConversion.target(of: "dkssud!") == .hangul)
        #expect(LayoutConversion.target(of: "123 !?") == nil)
        #expect(LayoutConversion.target(of: "") == nil)
    }

    /// Letters of both scripts in one run are re-read together; other characters stay.
    @Test func mixedRunsAndOtherCharacters() {
        #expect(LayoutConversion.convert("dks녕", to: .latin) == "dkssud")
        #expect(LayoutConversion.convert("dks녕", to: .hangul) == "안녕")
        #expect(LayoutConversion.convert("dkssud! gksrmf.", to: .hangul) == "안녕! 한글.")
        #expect(LayoutConversion.convert("(rk)", to: .hangul) == "(가)")
    }

    /// Keys that make no syllable stay single jamo; each one is one key (ㅁㄴㅇ ← asd).
    @Test func singleJamoConvertBack() throws {
        #expect(LayoutConversion.convert("ㅁㄴㅇ", to: .latin) == "asd")
        #expect(LayoutConversion.convert("asd", to: .hangul) == "ㅁㄴㅇ")
        let word = try #require(LayoutConversion.lastWord(in: "ㅁㄴㅇ", reachesStart: true))
        #expect(word.offset == 0)
        #expect(word.word == "ㅁㄴㅇ")
    }

    /// Shift chooses the double consonants and ㅒ·ㅖ on the Korean layout.
    @Test func shiftedKeysKeepTheirMeaning() {
        #expect(LayoutConversion.convert("Rk", to: .hangul) == "까")
        #expect(LayoutConversion.convert("까", to: .latin) == "Rk")
    }

    // MARK: the word before the caret

    @Test func theLastWordBeforeTheCaret() throws {
        let word = try #require(LayoutConversion.lastWord(in: "say dkssud", reachesStart: true))
        #expect(word.offset == 4)
        #expect(word.word == "dkssud")
        #expect(word.trailing == "")
    }

    /// "The word I just typed" includes the one just finished with Space.
    @Test func trailingSpacesAreSkippedAndKept() throws {
        let word = try #require(LayoutConversion.lastWord(in: "say dkssud  ", reachesStart: true))
        #expect(word.offset == 4)
        #expect(word.word == "dkssud")
        #expect(word.trailing == "  ")
    }

    /// A line break ends the search: the previous line is not "the word before the caret".
    @Test func aLineBreakIsNotSkipped() {
        #expect(LayoutConversion.lastWord(in: "dkssud\n", reachesStart: true) == nil)
        #expect(LayoutConversion.lastWord(in: "", reachesStart: true) == nil)
        #expect(LayoutConversion.lastWord(in: "   ", reachesStart: true) == nil)
    }

    /// Text read from the middle of a long word is not a whole word.
    @Test func aWordCutByTheReadWindowIsNotUsed() {
        #expect(LayoutConversion.lastWord(in: "dkssud", reachesStart: false) == nil)
        #expect(LayoutConversion.lastWord(in: "x dkssud", reachesStart: false)?.word == "dkssud")
    }

    @Test func utf16OffsetsAreUsed() throws {
        let word = try #require(LayoutConversion.lastWord(in: "😀 dkssud", reachesStart: true))
        #expect(word.offset == 3)
    }

    // MARK: asking again

    /// The same shortcut right after a fix puts back exactly what was there,
    /// even when converting back would differ (Hello → ㅗ디ㅣㅐ → hello).
    @Test func askingAgainRightAwayRestoresTheOriginal() {
        var toggle = ShortcutToggle()
        let edit = ShortcutToggle.Edit(location: 2, original: "Hello", replacement: "ㅗ디ㅣㅐ", previousMode: .latin)
        toggle.remember(edit)
        let first = toggle.takeRepeat()
        #expect(first == edit)
        #expect(toggle.takeRepeat() == nil) // once
    }

    @Test func anythingElseForgetsTheFix() {
        var toggle = ShortcutToggle()
        toggle.remember(ShortcutToggle.Edit(location: 0, original: "dkssud", replacement: "안녕", previousMode: .latin))
        toggle.forget()
        #expect(toggle.takeRepeat() == nil)
    }

    // MARK: terminals: the word from typed keys

    @Test func aTerminalWordIsWhatWasTyped() {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .latin) }
        #expect(word.shown == "dkssud")
        word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .hangul) }
        #expect(word.shown == "안녕")
    }

    /// Keys typed in both modes show as each mode composed them.
    @Test func modesMixInOneWord() {
        var word = TypedWord()
        for key in "dks" { word.letter(key, mode: .latin) }
        for key in "sud" { word.letter(key, mode: .hangul) }
        #expect(word.shown == "dks녕")
    }

    @Test func spacesAfterTheWordAreKept() {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .latin) }
        word.space()
        word.space()
        #expect(word.shown == "dkssud")
        #expect(word.trailingSpaces == 2)
        word.letter("r", mode: .latin) // a new word
        #expect(word.shown == "r")
        #expect(word.trailingSpaces == 0)
    }

    @Test func otherKeysClearTheWord() {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .latin) }
        word.clear()
        #expect(word.isEmpty)
        word.space()
        #expect(word.isEmpty) // spaces alone are not a word
    }

    /// Backspace while composing removes one key; after the syllable was committed
    /// it removes one character, as the terminal does.
    @Test func backspaceFollowsWhatTheTerminalShows() {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .hangul) }
        word.backspace(composing: true)
        #expect(word.shown == "안녀")
        word.backspace(composing: false)
        #expect(word.shown == "안")
        word.space()
        word.backspace(composing: false)
        #expect(word.shown == "안")
        #expect(word.trailingSpaces == 0)
        for key in "abc" { word.letter(key, mode: .latin) }
        word.backspace(composing: false)
        #expect(word.shown == "안ab")
    }

    /// After a fix the terminal shows the replacement, typed in the target mode.
    @Test func aFixedWordIsTheReplacement() {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .latin) }
        word.space()
        word.replace(with: "안녕", mode: .hangul)
        #expect(word.shown == "안녕")
        #expect(word.trailingSpaces == 1)
    }

    /// What the terminal fix erases and inserts: the word and its spaces.
    @Test func aTerminalFixKeepsTheSpaces() throws {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .latin) }
        word.space()
        let plan = try #require(word.conversion())
        #expect(plan.target == .hangul)
        #expect(plan.original == "dkssud ")
        #expect(plan.replacement == "안녕 ")
        #expect(TypedWord().conversion() == nil)
    }

    /// Digits and symbols are part of the word, as in apps that report text
    /// (`lastWord` stops only at whitespace). They stay as they are in the fix.
    @Test func digitsAndSymbolsArePartOfATerminalWord() throws {
        var word = TypedWord()
        for key in "dks" { word.letter(key, mode: .latin) }
        word.other(".")
        for key in "sud" { word.letter(key, mode: .latin) }
        word.other("!")
        #expect(word.shown == "dks.sud!")
        let plan = try #require(word.conversion())
        #expect(plan.replacement == "안.녕!")

        word = TypedWord()
        for key in "rk" { word.letter(key, mode: .hangul) }
        word.other("2")
        #expect(word.shown == "가2")
        #expect(try #require(word.conversion()).replacement == "rk2")

        word = TypedWord()
        word.other("1")
        word.other("2")
        #expect(word.shown == "12")
        #expect(word.conversion() == nil) // no letter: nothing to fix
    }

    @Test func backspaceRemovesATypedSymbol() {
        var word = TypedWord()
        for key in "dkssud" { word.letter(key, mode: .hangul) }
        word.other("?")
        word.backspace(composing: false)
        #expect(word.shown == "안녕")
    }

    /// The fix, then the shortcut again: the symbols must survive both ways.
    @Test func aFixedWordWithSymbolsConvertsBack() throws {
        var word = TypedWord()
        word.replace(with: "안녕!", mode: .hangul)
        #expect(word.shown == "안녕!")
        #expect(try #require(word.conversion()).replacement == "dkssud!")
        word.replace(with: "rk2", mode: .latin)
        #expect(word.shown == "rk2")
        #expect(try #require(word.conversion()).replacement == "가2")
    }

    /// Only text a terminal shows joins the word: not Return, Tab, Esc, arrows
    /// or function keys (private-use characters), and not spaces.
    @Test func onlyPrintedTextJoinsTheWord() {
        for text in ["1", "!", ".", "-", "/", "~", "₩"] { #expect(TypedWord.isPrinted(text), "\(text)") }
        for text in ["", " ", "\r", "\t", "\u{1B}", "\u{7F}", "\u{F700}", "\u{F704}"] {
            #expect(!TypedWord.isPrinted(text), "\(text.unicodeScalars.map(\.value))")
        }
    }

    // MARK: terminals: one request until the keys are sent

    /// The fix waits for the shortcut's modifiers to be released. Tapping ↩ again
    /// with ⌥ still held is the same request: it used to replace the waiting one,
    /// which dropped the remembered word, so every later press had nothing to fix.
    @Test func pressingAgainWhileWaitingIsTheSameRequest() {
        var pending = PendingKeyFix()
        let first = pending.start()
        let again = pending.start()
        #expect(first)
        #expect(!again)
        #expect(pending.isWaiting)
        pending.end()
        let next = pending.start()
        #expect(next)
    }
}
