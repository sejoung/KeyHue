/// ADR 0067: a terminal sends typed text to its program at once and reports no
/// text positions, so a range cannot be replaced. The input method erases the
/// word with Backspace keys and then inserts the fix. One Backspace removes one
/// character: precomposed syllables and compatibility jamo are one scalar each.
public struct KeyReplacement: Equatable, Sendable {
    public let erase: Int
    public let insert: String

    public init(erase: Int, insert: String) {
        self.erase = erase
        self.insert = insert
    }

    public init(correcting edit: CorrectionEdit) {
        self.init(erase: edit.original.unicodeScalars.count, insert: edit.replacement)
    }

    public init(undoing edit: CorrectionEdit) {
        self.init(erase: edit.replacement.unicodeScalars.count, insert: edit.original)
    }
}

/// The input method's own Backspaces on their way through the terminal and back
/// into the input method. They pass untouched, never as the user's Backspace
/// (which would undo the correction). The insert follows the last one.
public struct PostedBackspaces: Sendable {
    public enum Arrival: Equatable, Sendable {
        case notOurs
        case passThrough
        /// The last one: insert once the terminal has handled it.
        case passThroughLast
    }

    private var remaining = 0
    private var arrivedCount = 0

    public init() {}

    public var isPending: Bool { remaining > 0 }

    public mutating func post(_ count: Int) {
        remaining = count
        arrivedCount = 0
    }

    public mutating func arrived(isBackspace: Bool) -> Arrival {
        guard isBackspace, remaining > 0 else { return .notOurs }
        remaining -= 1
        arrivedCount += 1
        return remaining == 0 ? .passThroughLast : .passThrough
    }

    /// Forgets keys that never arrived. Returns how many did.
    public mutating func abandon() -> Int {
        defer { remaining = 0; arrivedCount = 0 }
        return arrivedCount
    }
}
