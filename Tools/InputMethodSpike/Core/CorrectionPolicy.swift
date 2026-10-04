import KeyHueCore

/// Where a decision is made. Any exclusion wins over the mode.
public struct CorrectionEnvironment: Equatable, Sendable {
    public var mode: CorrectionMode
    public var secureInput = false
    /// On the user's exclusion list (terminals and code editors by default).
    public var appExcluded = false
    /// The client's range replacement and original check are not verified.
    public var cannotReplace = false
    /// The user's exception words and the shipped reported words (ADR 0065).
    public var ignoredWords: Set<String> = []

    public init(mode: CorrectionMode) { self.mode = mode }

}

/// The language detector seen by the policy. Returns the Hangul text for a word
/// typed on the Latin layout, or nil. Manual and automatic use separate thresholds.
public protocol CorrectionJudging: AnyObject {
    /// False while the model is still loading; the policy then skips without asking.
    var isReady: Bool { get }
    func hangul(for word: String, mode: CorrectionMode) -> String?
}

/// Replace `replacement`'s range at `location` with `original` to undo, or the
/// reverse to correct. Offsets and lengths are UTF-16, as IMK clients use.
public struct CorrectionEdit: Equatable, Sendable {
    public let location: Int
    public let original: String
    public let replacement: String

    public init(location: Int, original: String, replacement: String) {
        self.location = location
        self.original = original
        self.replacement = replacement
    }
}

public enum CorrectionDecision: Equatable, Sendable {
    /// Nothing to decide: no word was typed, or this event is not a decision point.
    case none
    /// Replace `original` with `replacement`. Automatic also selects Hangul;
    /// manual leaves the mode the user already chose.
    case correct(CorrectionEdit, selectHangul: Bool)
    /// Replace `replacement` with `original`. Only automatic restores Latin.
    case undo(CorrectionEdit, selectLatin: Bool)
    /// A decision point with a word, without a correction. For the log only.
    case skipped(CorrectionSkip)
}

/// Why a word was not corrected. Logged without the word (ADR 0064).
public enum CorrectionSkip: Equatable, Sendable {
    case secureInput, appExcluded, cannotReplace
    /// The model is still loading after the server started.
    case detectorNotReady
    /// A user exception word or a shipped reported word (ADR 0065).
    case ignoredWord
    /// The detector kept the word.
    case notMistyped
    /// The word stopped being a candidate before the decision.
    case dropped(CorrectionDrop)
    /// The second signal of one switch (mode callback and selection notification).
    case duplicateSignal
    /// The user undid this word's correction while the input method runs (ADR 0065).
    case alreadyUndone
    /// Automatic: a switch cancels the word and any undo (ADR 0058).
    case externalSwitch
}

public enum CorrectionDrop: Equatable, Sendable {
    case interrupted(CorrectionInterruption)
    case notAtWordStart, caretMoved, notALetter, tooLong, edited
    /// Manual: a second Space after the word.
    case extraSpace
    /// Manual: switched to Latin or another source before Hangul.
    case switchedAway
}

/// Events that end the current word and any undo.
public enum CorrectionInterruption: Equatable, Sendable {
    case otherKey, returnKey, tab, mouse, cursorMoved, contextChanged, externalEdit
}

/// Pure decisions for ADR 0064. The IMK adapter reports events, applies edits,
/// verifies the client's text before every edit and logs `.skipped` reasons;
/// this type never edits.
///
/// In automatic mode the adapter must not report the mode callback caused by its
/// own Hangul request: every reported switch is external and cancels (ADR 0058).
public struct CorrectionPolicy {
    /// Same limit as the wrong-language warning's word tracker (ADR 0041).
    public static let maximumWordLength = 40
    /// Undone words kept in memory (ADR 0065); the oldest is forgotten first.
    public static let undoneWordLimit = 200

    private let judge: CorrectionJudging
    private var word = ""
    private var start: Int?
    /// Manual: the word was finished with one Space.
    private var finished = false
    /// Words whose correction the user undid, oldest first. Memory only.
    private var undoneWords: [String] = []
    private var undoable: (edit: CorrectionEdit, automatic: Bool)?
    /// Why the last Latin word stopped being a candidate, until the next decision.
    private var dropReason: CorrectionDrop?

    public init(judge: CorrectionJudging) {
        self.judge = judge
    }

    /// A Latin word is being typed. A word finished with Space is not: the next
    /// letter starts a new word, so the adapter must check for a word start.
    public var isTrackingWord: Bool { start != nil && !finished }

    private mutating func reset() {
        word = ""; start = nil; finished = false; undoable = nil; dropReason = nil
    }

    private mutating func drop(_ reason: CorrectionDrop) {
        reset()
        dropReason = reason
    }

    /// `atWordStart`: the caret is at the document start or after whitespace. It
    /// queries the client, so it is evaluated only for a new word or after the
    /// caret jumped, never while the word continues.
    public mutating func letter(_ key: Character, caret: Int, atWordStart: @autoclosure () -> Bool, mode: ProbeSession.Mode,
                                environment: CorrectionEnvironment) -> CorrectionDecision {
        undoable = nil
        guard environment.mode != .off, mode == .latin else { reset(); return .none }
        guard key.isASCII, key.isLetter else {
            if !word.isEmpty { drop(.notALetter) }
            return .none
        }
        if finished { reset() }
        if let start, caret != start + word.utf16.count { drop(.caretMoved) }
        if start == nil {
            guard atWordStart() else {
                // Keep the first reason while the same dropped word continues.
                if dropReason == nil { drop(.notAtWordStart) }
                return .none
            }
            dropReason = nil
            start = caret
        }
        guard word.count < Self.maximumWordLength else { drop(.tooLong); return .none }
        word.append(key)
        return .none
    }

    public mutating func space(caret: Int, mode: ProbeSession.Mode, environment: CorrectionEnvironment) -> CorrectionDecision {
        undoable = nil
        guard environment.mode != .off, mode == .latin else { reset(); return .none }
        let automatic = environment.mode == .automatic
        guard let start, !word.isEmpty else {
            // Automatic decides at Space: report a word dropped since the last decision.
            guard automatic, let dropReason else { return .none }
            reset()
            return .skipped(.dropped(dropReason))
        }
        if finished { drop(.extraSpace); return .none }
        guard caret == start + word.utf16.count else {
            guard automatic else { drop(.caretMoved); return .none }
            reset()
            return .skipped(.dropped(.caretMoved))
        }
        guard automatic else { finished = true; return .none }
        let word = self.word
        reset() // automatic decides once per word
        if let skip = skipBeforeJudging(word, environment) { return .skipped(skip) }
        guard let hangul = judge.hangul(for: word, mode: .automatic) else { return .skipped(.notMistyped) }
        let edit = CorrectionEdit(location: start, original: word + " ", replacement: hangul + " ")
        undoable = (edit, true)
        return .correct(edit, selectHangul: true)
    }

    /// A mode change reached the session: the mode callback or the selection
    /// notification, possibly both for one switch. `nil` is a foreign source.
    public mutating func modeSignal(to target: ProbeSession.Mode?, environment: CorrectionEnvironment) -> CorrectionDecision {
        switch environment.mode {
        case .off:
            reset(); return .none
        case .automatic:
            let hadWork = undoable != nil || !word.isEmpty
            reset()
            return hadWork ? .skipped(.externalSwitch) : .none
        case .manual:
            break
        }
        if let undoable, !undoable.automatic {
            if target == .hangul { return .skipped(.duplicateSignal) } // the same switch again
            reset(); return .none
        }
        guard target == .hangul else {
            if !word.isEmpty { drop(.switchedAway) }
            return .none
        }
        guard let start, !word.isEmpty else {
            guard let dropReason else { return .none }
            reset()
            return .skipped(.dropped(dropReason))
        }
        let word = self.word
        let boundary = finished ? " " : ""
        reset()
        if let skip = skipBeforeJudging(word, environment) { return .skipped(skip) }
        guard let hangul = judge.hangul(for: word, mode: .manual) else { return .skipped(.notMistyped) }
        let edit = CorrectionEdit(location: start, original: word + boundary, replacement: hangul + boundary)
        undoable = (edit, false)
        return .correct(edit, selectHangul: false)
    }

    /// Exclusions, exception words, undone words and readiness, in that order.
    /// None of them asks the detector.
    private func skipBeforeJudging(_ word: String, _ environment: CorrectionEnvironment) -> CorrectionSkip? {
        if let exclusion = environment.exclusion { return exclusion }
        if environment.ignoredWords.contains(word) { return .ignoredWord }
        if undoneWords.contains(word) { return .alreadyUndone }
        return judge.isReady ? nil : .detectorNotReady
    }

    private mutating func remember(undone word: String) {
        undoneWords.removeAll { $0 == word }
        undoneWords.append(word)
        if undoneWords.count > Self.undoneWordLimit { undoneWords.removeFirst(undoneWords.count - Self.undoneWordLimit) }
    }

    /// Immediately after a correction only. The adapter checks the visible result
    /// itself: Backspace can arrive before the correction was observed. An undo is
    /// the user's "this was wrong" (ADR 0065).
    public mutating func backspace() -> CorrectionDecision {
        guard let undoable else {
            if !word.isEmpty { drop(.edited) } // edited words are excluded (ADR 0041)
            return .none
        }
        reset()
        let edit = undoable.edit
        let typed = edit.original.hasSuffix(" ") ? String(edit.original.dropLast()) : edit.original
        remember(undone: typed)
        guard undoable.automatic else { return .undo(edit, selectLatin: false) }
        // Automatic undo restores the word without its Space (INPUT_METHOD_DESIGN §5).
        // The restored word is still being typed; its next Space reports it as undone.
        let original = typed
        word = original; start = edit.location
        return .undo(CorrectionEdit(location: edit.location, original: original, replacement: edit.replacement), selectLatin: true)
    }

    public mutating func interrupt(_ interruption: CorrectionInterruption) {
        if word.isEmpty { undoable = nil } else { drop(.interrupted(interruption)) }
    }
}

extension CorrectionEnvironment {
    /// A secure field first, then the app list, then the client's capability.
    var exclusion: CorrectionSkip? {
        if secureInput { return .secureInput }
        if appExcluded { return .appExcluded }
        if cannotReplace { return .cannotReplace }
        return nil
    }
}

extension CorrectionSkip {
    /// Short, text-free name for the input method log.
    public var logName: String {
        switch self {
        case .secureInput: return "secureInput"
        case .appExcluded: return "appExcluded"
        case .cannotReplace: return "cannotReplace"
        case .detectorNotReady: return "detectorNotReady"
        case .ignoredWord: return "ignoredWord"
        case .notMistyped: return "notMistyped"
        case .dropped(let drop): return "dropped." + drop.logName
        case .duplicateSignal: return "duplicateSignal"
        case .alreadyUndone: return "alreadyUndone"
        case .externalSwitch: return "externalSwitch"
        }
    }
}

extension CorrectionDrop {
    var logName: String {
        switch self {
        case .interrupted(let interruption): return "interrupted.\(interruption)"
        case .notAtWordStart: return "notAtWordStart"
        case .caretMoved: return "caretMoved"
        case .notALetter: return "notALetter"
        case .tooLong: return "tooLong"
        case .edited: return "edited"
        case .extraSpace: return "extraSpace"
        case .switchedAway: return "switchedAway"
        }
    }
}
