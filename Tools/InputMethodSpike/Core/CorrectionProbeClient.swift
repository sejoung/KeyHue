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

/// How IMK client ranges are read before an edit.
extension CorrectionProbe {
    /// IMK uses {NSNotFound, NSNotFound} when no inline range is available,
    /// including after committing in the Cocoa probe. Interpret it as inactive
    /// only for the same retained client that already reported a real range.
    /// Unknown clients and malformed ranges remain ineligible for replacement.
    public static func hasMarkedText(range: NSRange, hasReportedMarkedRange: Bool) -> Bool {
        if range.length == 0 { return false }
        if range.location == NSNotFound, range.length == NSNotFound {
            return !hasReportedMarkedRange
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
