import Foundation

/// The client as `CorrectionProbe` sees it: identity, mode, ranges and text.
public protocol CorrectionProbeClient: AnyObject {
    var identity: String { get }
    var mode: ProbeSession.Mode? { get }
    var selection: NSRange { get }
    var hasMarkedText: Bool { get }
    var markedRange: NSRange { get }
    func text(in range: NSRange) -> String?
    func replace(_ range: NSRange, with text: String)
    func select(_ mode: ProbeSession.Mode)
}

extension CorrectionProbeClient {
    public var markedRange: NSRange {
        NSRange(location: NSNotFound, length: hasMarkedText ? NSNotFound : 0)
    }
}

extension CorrectionProbe {
    /// Which check refused an automatic correction. Logged by name, never with text.
    public enum Refusal: String, Sendable {
        /// Another edit was still being applied or confirmed.
        case busy
        case invalidRequest
        /// The user undid this word here; it is not corrected again.
        case rejectedBefore
        case otherSession
        case notLatin
        /// The caret is not right after the word and its Space.
        case caretMoved
        /// The client no longer shows the word as typed (another app's edit, autocorrection).
        case textChanged
        /// The client reports a composition, or cannot say it has none.
        case composing
        /// Another event arrived while the client was read.
        case interrupted
    }
}

/// How IMK client ranges are read before an edit.
extension CorrectionProbe {
    /// IMK uses {NSNotFound, NSNotFound} when no inline range is available,
    /// including after committing in the Cocoa probe. Interpret it as inactive
    /// while this session composes nothing: only this input method composes in
    /// its client, and English is never composed (ADR 0081), so a client that
    /// only received English never reports a range. While composing, only the
    /// same retained client that already reported a real range is trusted.
    /// Malformed ranges remain ineligible for replacement.
    public static func hasMarkedText(range: NSRange, hasReportedMarkedRange: Bool, sessionComposing: Bool) -> Bool {
        if range.length == 0 { return false }
        if range.location == NSNotFound, range.length == NSNotFound {
            return sessionComposing && !hasReportedMarkedRange
        }
        return true
    }

    /// IMK may report the current marked Latin character as selected even when
    /// its inline caret is at the end. Accept only that exact one-unit marked
    /// range while tracking; actual replacement still requires an empty selection.
    public static func typingCaret(selection: NSRange, markedRange: NSRange) -> Int? {
        guard selection.location >= 0, selection.location != NSNotFound else { return nil }
        if selection.length == 0 { return selection.location }
        guard selection == markedRange, markedRange.length == 1,
              markedRange.location < Int.max - 1 else { return nil }
        return markedRange.location + 1
    }
}
