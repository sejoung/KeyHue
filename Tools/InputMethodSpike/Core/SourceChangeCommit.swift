import Foundation

/// A selection of another input source can reach a session only as the TIS
/// notification, without a callback. The composition is committed then only
/// where the client still shows exactly it (`ProbeSession.finishAfterSourceChange`).
public enum SourceChangeCommit {
    /// The client's mark is `pendingText`, whole, with the caret right after it.
    public static func marksComposition(_ pendingText: String, markedRange: NSRange, selection: NSRange) -> Bool {
        guard markedRange.location != NSNotFound, markedRange.location >= 0,
              markedRange.length > 0,
              markedRange.length == pendingText.utf16.count,
              markedRange.location <= Int.max - markedRange.length else { return false }
        return CorrectionProbe.typingCaret(selection: selection, markedRange: markedRange) == NSMaxRange(markedRange)
    }
}
