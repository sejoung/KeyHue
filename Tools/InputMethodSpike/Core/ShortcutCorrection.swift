import KeyHueCore

/// ADR 0068: the user asks for a fix with a shortcut, and whatever they point at
/// is re-read as typed on the other layout. There is no detector and no word
/// tracking that could silently drop a word: the input method reads the text
/// before the caret (or the selection) at the moment of asking.
public enum LayoutConversion {
    /// Letters of either script; everything else stays as it is.
    private static func isLetter(_ character: Character) -> Bool {
        (character.isASCII && character.isLetter) || isHangul(character)
    }

    private static func isHangul(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(value) || (0x3131...0x318E).contains(value)
    }

    /// The mode the text was meant for: the other script of its last letter.
    /// nil when there is no letter.
    public static func target(of text: String) -> ProbeSession.Mode? {
        guard let last = text.last(where: isLetter) else { return nil }
        return isHangul(last) ? .latin : .hangul
    }

    /// Re-reads every run of letters as the keys that typed it, then as typed in
    /// `target`. Letters of both scripts in one run are read together.
    public static func convert(_ text: String, to target: ProbeSession.Mode) -> String {
        var result = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let keys = run.map { character -> String in
                character.isASCII ? String(character) : (Dubeolsik.keys(for: String(character)) ?? String(character))
            }.joined()
            result += target == .hangul ? Dubeolsik.compose(keys: keys).text : keys
            run = ""
        }
        for character in text {
            if isLetter(character) { run.append(character) } else { flush(); result.append(character) }
        }
        flush()
        return result
    }

    public struct Word: Equatable, Sendable {
        /// UTF-16 offset of the word in the text that was searched.
        public let offset: Int
        public let word: String
        /// Spaces and tabs after the word, kept as they are.
        public let trailing: String
    }

    /// The last word before the caret: spaces and tabs right before the caret are
    /// skipped (the word just finished with Space), then back to whitespace.
    /// - Parameter reachesStart: `text` starts at the document start. Otherwise a
    ///   word that fills the whole text may be cut and is not used.
    public static func lastWord(in text: String, reachesStart: Bool) -> Word? {
        let trailingCount = text.reversed().prefix { $0 == " " || $0 == "\t" }.count
        let beforeTrailing = text.dropLast(trailingCount)
        let word = beforeTrailing.reversed().prefix { !$0.isWhitespace }
        guard !word.isEmpty else { return nil }
        let wordStart = beforeTrailing.index(beforeTrailing.endIndex, offsetBy: -word.count)
        guard reachesStart || wordStart != text.startIndex else { return nil }
        return Word(offset: text[..<wordStart].utf16.count, word: String(beforeTrailing[wordStart...]),
                    trailing: String(text.suffix(trailingCount)))
    }
}

/// Pressing the shortcut again right away puts back exactly what was there, even
/// when converting back would differ (Hello → ㅗ디ㅣㅐ → hello).
public struct ShortcutToggle: Sendable {
    public struct Edit: Equatable, Sendable {
        /// UTF-16 location of the replacement (unused for terminals).
        public let location: Int
        public let original: String
        public let replacement: String
        /// The mode before the fix, restored with the original.
        public let previousMode: ProbeSession.Mode

        public init(location: Int, original: String, replacement: String, previousMode: ProbeSession.Mode) {
            self.location = location
            self.original = original
            self.replacement = replacement
            self.previousMode = previousMode
        }
    }

    private var last: Edit?

    public init() {}

    public mutating func remember(_ edit: Edit) { last = edit }

    /// The last fix, once, when the shortcut is pressed again right away.
    public mutating func takeRepeat() -> Edit? {
        defer { last = nil }
        return last
    }

    /// Anything else happened: the next press is a new request.
    public mutating func forget() { last = nil }
}

/// A terminal fix waits for the shortcut's modifiers to be released. Pressing
/// the shortcut again meanwhile (⌥ held, ↩ tapped again) is the same request.
public struct PendingKeyFix: Sendable {
    public private(set) var isWaiting = false

    public init() {}

    /// false while a fix is already waiting.
    public mutating func start() -> Bool {
        guard !isWaiting else { return false }
        isWaiting = true
        return true
    }

    /// Sent, expired, or given up.
    public mutating func end() { isWaiting = false }
}

/// Terminals report no text, so the word before the caret is what was typed
/// since the last boundary, in the modes it was typed in (ADR 0068).
public struct TypedWord: Sendable {
    private var runs: [(mode: ProbeSession.Mode, keys: String)] = []
    public private(set) var trailingSpaces = 0

    public init() {}

    public var isEmpty: Bool { runs.isEmpty }

    /// What the terminal shows for the word, without its spaces.
    public var shown: String {
        runs.map { $0.mode == .hangul ? Dubeolsik.compose(keys: $0.keys).text : $0.keys }.joined()
    }

    public mutating func letter(_ key: Character, mode: ProbeSession.Mode) {
        if trailingSpaces > 0 { clear() }
        if let last = runs.last, last.mode == mode {
            runs[runs.count - 1].keys.append(key)
        } else {
            runs.append((mode, String(key)))
        }
    }

    /// A Space after a word is kept with it; spaces alone are not a word.
    public mutating func space() {
        if !runs.isEmpty { trailingSpaces += 1 }
    }

    /// Return, Tab, arrows, other keys, clicks and context changes.
    public mutating func clear() {
        runs = []
        trailingSpaces = 0
    }

    /// While composing, Backspace removes one key; otherwise the terminal removes
    /// one character.
    public mutating func backspace(composing: Bool) {
        if trailingSpaces > 0 { trailingSpaces -= 1; return }
        guard let last = runs.last else { return }
        var keys = last.keys
        if composing || last.mode == .latin {
            keys.removeLast()
        } else {
            let shown = Dubeolsik.compose(keys: keys).text
            keys = Dubeolsik.keys(for: String(shown.dropLast())) ?? ""
        }
        if keys.isEmpty { runs.removeLast() } else { runs[runs.count - 1].keys = keys }
    }

    /// After a fix the terminal shows `text`, as if typed in `mode`.
    public mutating func replace(with text: String, mode: ProbeSession.Mode) {
        let keys = mode == .hangul ? (Dubeolsik.keys(for: text) ?? text) : text
        runs = keys.isEmpty ? [] : [(mode, keys)]
    }

    public struct Plan: Equatable, Sendable {
        public let target: ProbeSession.Mode
        /// What the terminal shows now and what replaces it, spaces included.
        public let original: String
        public let replacement: String
    }

    public func conversion() -> Plan? {
        let shown = self.shown
        guard let target = LayoutConversion.target(of: shown) else { return nil }
        let spaces = String(repeating: " ", count: trailingSpaces)
        return Plan(target: target, original: shown + spaces,
                    replacement: LayoutConversion.convert(shown, to: target) + spaces)
    }
}
