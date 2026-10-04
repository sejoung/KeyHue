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

/// The language detector seen by the policy. Manual and automatic use separate thresholds.
public protocol CorrectionJudging: AnyObject {
    /// False while the model is still loading; the policy then skips without asking.
    var isReady: Bool { get }
    /// The text the user meant for `keys` typed in `typedIn`, or nil to keep them:
    /// Hangul for Latin-mode keys, English for Hangul-mode keys (ADR 0067).
    func replacement(for keys: String, typedIn: ProbeSession.Mode, mode: CorrectionMode) -> String?
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
    /// Manual: switched to the word's own mode or another source, not the other mode.
    case switchedAway
}

/// Events that end the current word and any undo.
public enum CorrectionInterruption: Equatable, Sendable {
    case otherKey, returnKey, tab, mouse, cursorMoved, contextChanged, externalEdit
}

/// Pure decisions for ADR 0064 and 0067. The IMK adapter reports events, applies
/// edits, verifies the client's text before every edit and logs `.skipped`
/// reasons; this type never edits.
///
/// Manual mode tracks the last word in either mode and corrects it when the user
/// switches to the other mode. A word is its keys; the client shows them as typed
/// (Latin) or composed (Hangul). Automatic corrects only Latin-mode words.
///
/// A client that reports no positions (a terminal) passes a nil caret: the word
/// is then tracked by keys alone and the adapter erases it with keys.
///
/// In automatic mode the adapter must not report the mode callback caused by its
/// own Hangul request: every reported switch is external and cancels (ADR 0058).
public struct CorrectionPolicy {
    /// Same limit as the wrong-language warning's word tracker (ADR 0041).
    public static let maximumWordLength = 40
    /// Undone words kept in memory (ADR 0065); the oldest is forgotten first.
    public static let undoneWordLimit = 200

    private let judge: CorrectionJudging
    /// The keys of the current word, as typed.
    private var word = ""
    private var wordMode = ProbeSession.Mode.latin
    private var start: Int?
    /// The client reported a caret when the word started.
    private var positionsKnown = true
    /// Manual: the word was finished with one Space.
    private var finished = false
    /// Words whose correction the user undid, as they were shown, oldest first. Memory only.
    private var undoneWords: [String] = []
    /// `target`: the mode switched to (manual), to recognize the switch's second signal.
    private var undoable: (edit: CorrectionEdit, automatic: Bool, target: ProbeSession.Mode)?
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

    /// What the client shows for the current word.
    private var shown: String {
        wordMode == .latin ? word : Dubeolsik.compose(keys: word).text
    }

    /// Manual tracks both modes; automatic only Latin.
    private func tracks(_ mode: ProbeSession.Mode, _ environment: CorrectionEnvironment) -> Bool {
        switch environment.mode {
        case .off: return false
        case .manual: return true
        case .automatic: return mode == .latin
        }
    }

    /// The caret is right after the word, or both are unknown (a terminal).
    private func isAtWordEnd(_ caret: Int?) -> Bool {
        guard let start else { return false }
        guard let caret else { return !positionsKnown }
        return positionsKnown && caret == start + shown.utf16.count
    }

    /// `caret`: nil when the client reports no positions (a terminal, ADR 0067).
    /// `atWordStart`: the caret is at the document start or after whitespace. It
    /// queries the client, so it is evaluated only for a new word or after the
    /// caret jumped, never while the word continues.
    public mutating func letter(_ key: Character, caret: Int?, atWordStart: @autoclosure () -> Bool, mode: ProbeSession.Mode,
                                environment: CorrectionEnvironment) -> CorrectionDecision {
        undoable = nil
        guard tracks(mode, environment) else { reset(); return .none }
        guard key.isASCII, key.isLetter else {
            if !word.isEmpty { drop(.notALetter) }
            return .none
        }
        if finished { reset() }
        if start != nil, wordMode != mode { reset() } // a new word in the other mode
        if start != nil, !isAtWordEnd(caret) { drop(.caretMoved) }
        if start == nil {
            guard atWordStart() else {
                // Keep the first reason while the same dropped word continues.
                if dropReason == nil { drop(.notAtWordStart) }
                return .none
            }
            dropReason = nil
            start = caret ?? 0
            positionsKnown = caret != nil
            wordMode = mode
        }
        guard word.count < Self.maximumWordLength else { drop(.tooLong); return .none }
        word.append(key)
        return .none
    }

    public mutating func space(caret: Int?, mode: ProbeSession.Mode, environment: CorrectionEnvironment) -> CorrectionDecision {
        undoable = nil
        guard tracks(mode, environment) else { reset(); return .none }
        let automatic = environment.mode == .automatic
        guard let start, !word.isEmpty else {
            // Automatic decides at Space: report a word dropped since the last decision.
            guard automatic, let dropReason else { return .none }
            reset()
            return .skipped(.dropped(dropReason))
        }
        if finished { drop(.extraSpace); return .none }
        guard wordMode == mode else { reset(); return .none }
        guard isAtWordEnd(caret) else {
            guard automatic else { drop(.caretMoved); return .none }
            reset()
            return .skipped(.dropped(.caretMoved))
        }
        guard automatic else { finished = true; return .none }
        let word = self.word
        reset() // automatic decides once per word
        if let skip = skipBeforeJudging(word, environment) { return .skipped(skip) }
        guard let hangul = judge.replacement(for: word, typedIn: .latin, mode: .automatic) else { return .skipped(.notMistyped) }
        let edit = CorrectionEdit(location: start, original: word + " ", replacement: hangul + " ")
        undoable = (edit, true, .hangul)
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
            if target == undoable.target { return .skipped(.duplicateSignal) } // the same switch again
            reset(); return .none
        }
        guard let target else {
            if !word.isEmpty { drop(.switchedAway) }
            return .none
        }
        guard let start, !word.isEmpty else {
            guard let dropReason else { return .none }
            reset()
            return .skipped(.dropped(dropReason))
        }
        // Only a switch to the other mode asks for a fix.
        guard target != wordMode else { drop(.switchedAway); return .none }
        let keys = word, typedIn = wordMode, shown = self.shown
        let boundary = finished ? " " : ""
        reset()
        if let skip = skipBeforeJudging(shown, environment) { return .skipped(skip) }
        guard let meant = judge.replacement(for: keys, typedIn: typedIn, mode: .manual) else { return .skipped(.notMistyped) }
        let edit = CorrectionEdit(location: start, original: shown + boundary, replacement: meant + boundary)
        undoable = (edit, false, target)
        return .correct(edit, selectHangul: false)
    }

    /// Exclusions, exception words, undone words and readiness, in that order.
    /// None of them asks the detector. Words are compared as the user saw them.
    private func skipBeforeJudging(_ shown: String, _ environment: CorrectionEnvironment) -> CorrectionSkip? {
        if let exclusion = environment.exclusion { return exclusion }
        if environment.ignoredWords.contains(shown) { return .ignoredWord }
        if undoneWords.contains(shown) { return .alreadyUndone }
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
        word = original; start = edit.location; wordMode = .latin; positionsKnown = true
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
