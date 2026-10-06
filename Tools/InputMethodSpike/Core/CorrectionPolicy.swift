import KeyHueCore

/// Where a decision is made. Any exclusion wins over the mode.
public struct CorrectionEnvironment: Equatable, Sendable {
    public var mode: CorrectionMode
    public var secureInput = false
    /// On the user's exclusion list.
    public var appExcluded = false
    /// The client's range replacement and original check are not verified.
    public var cannotReplace = false
    /// The user's exception words and the shipped reported words (ADR 0065).
    public var ignoredWords: Set<String> = []

    public init(mode: CorrectionMode) { self.mode = mode }

}

/// The language detector seen by the automatic policy.
public protocol CorrectionJudging: AnyObject {
    /// False while the model is still loading; the policy then skips without asking.
    var isReady: Bool { get }
    /// The Hangul meant by a word typed on the Latin layout, or nil to keep it.
    func hangul(for word: String) -> String?
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
    /// Replace `original` with `replacement` and select Hangul.
    case correct(CorrectionEdit, selectHangul: Bool)
    /// Replace `replacement` with `original` and restore Latin.
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
    /// The user undid this word's correction while the input method runs (ADR 0065).
    case alreadyUndone
    /// A switch cancels the word and any undo (ADR 0058).
    case externalSwitch
}

public enum CorrectionDrop: Equatable, Sendable {
    case interrupted(CorrectionInterruption)
    case notAtWordStart, caretMoved, notALetter, tooLong, edited
}

/// Events that end the current word and any undo.
public enum CorrectionInterruption: Equatable, Sendable {
    case otherKey, mouse, cursorMoved, contextChanged, externalEdit
}

/// Pure decisions for automatic correction (ADR 0064): a Latin-mode word is
/// judged at Space and corrected to Hangul. The IMK adapter reports events,
/// applies edits, verifies the client's text before every edit and logs
/// `.skipped` reasons; this type never edits. Fixes the user asks for with the
/// shortcut are not decided here (ADR 0068, `LayoutConversion`).
///
/// The adapter must not report the mode callback caused by its own Hangul
/// request: every reported switch is external and cancels (ADR 0058).
public struct CorrectionPolicy {
    /// Same limit as the wrong-language warning's word tracker (ADR 0041).
    public static let maximumWordLength = 40
    /// Undone words kept in memory (ADR 0065); the oldest is forgotten first.
    public static let undoneWordLimit = 200

    private let judge: CorrectionJudging
    private var word = ""
    private var start: Int?
    /// Words whose correction the user undid, oldest first. Memory only.
    private var undoneWords: [String] = []
    private var undoable: CorrectionEdit?
    /// Why the last Latin word stopped being a candidate, until the next decision.
    private var dropReason: CorrectionDrop?

    public init(judge: CorrectionJudging) {
        self.judge = judge
    }

    /// A Latin word is being typed.
    public var isTrackingWord: Bool { start != nil }

    private mutating func reset() {
        word = ""; start = nil; undoable = nil; dropReason = nil
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
        guard environment.mode == .automatic, mode == .latin else { reset(); return .none }
        guard key.isASCII, key.isLetter else {
            if !word.isEmpty { drop(.notALetter) }
            return .none
        }
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
        guard environment.mode == .automatic, mode == .latin else { reset(); return .none }
        guard let start, !word.isEmpty else {
            // Report a word dropped since the last decision.
            guard let dropReason else { return .none }
            reset()
            return .skipped(.dropped(dropReason))
        }
        guard caret == start + word.utf16.count else {
            reset()
            return .skipped(.dropped(.caretMoved))
        }
        let word = self.word
        reset() // decided once per word
        if let skip = skipBeforeJudging(word, environment) { return .skipped(skip) }
        guard let hangul = judge.hangul(for: word) else { return .skipped(.notMistyped) }
        let edit = CorrectionEdit(location: start, original: word + " ", replacement: hangul + " ")
        undoable = edit
        return .correct(edit, selectHangul: true)
    }

    /// A mode change reached the session: the mode callback or the selection
    /// notification. Any external switch cancels the word and its undo (ADR 0058).
    // periphery:ignore:parameters target - any external switch cancels, whatever its target (ADR 0058)
    public mutating func modeSignal(to target: ProbeSession.Mode?, environment: CorrectionEnvironment) -> CorrectionDecision {
        let hadWork = undoable != nil || !word.isEmpty
        reset()
        return environment.mode == .automatic && hadWork ? .skipped(.externalSwitch) : .none
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
        guard let edit = undoable else {
            if !word.isEmpty { drop(.edited) } // edited words are excluded (ADR 0041)
            return .none
        }
        reset()
        let typed = String(edit.original.dropLast())
        remember(undone: typed)
        // Undo restores the word without its Space (INPUT_METHOD_DESIGN §5).
        // The restored word is still being typed; its next Space reports it as undone.
        word = typed; start = edit.location
        return .undo(CorrectionEdit(location: edit.location, original: typed, replacement: edit.replacement), selectLatin: true)
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
        }
    }
}
