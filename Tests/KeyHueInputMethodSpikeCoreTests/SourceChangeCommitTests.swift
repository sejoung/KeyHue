import Foundation
import Testing
@testable import KeyHueInputMethodSpikeCore

/// A source selected without a callback commits the composition only where the
/// client still marks exactly it, with the caret at its end.
@Suite("Source change commit")
struct SourceChangeCommitTests {
    @Test func theExactMarkWithTheCaretAtItsEndIsCommitted() {
        #expect(SourceChangeCommit.marksComposition("한", markedRange: NSRange(location: 4, length: 1),
                                                    selection: NSRange(location: 5, length: 0)))
        // IMK may report the marked character itself as selected.
        #expect(SourceChangeCommit.marksComposition("한", markedRange: NSRange(location: 4, length: 1),
                                                    selection: NSRange(location: 4, length: 1)))
    }

    @Test func aMovedCaretOrAnotherMarkIsLeftAlone() {
        let marked = NSRange(location: 4, length: 1)
        #expect(!SourceChangeCommit.marksComposition("한", markedRange: marked, selection: NSRange(location: 2, length: 0)))
        #expect(!SourceChangeCommit.marksComposition("한", markedRange: marked, selection: NSRange(location: 0, length: 5)))
        #expect(!SourceChangeCommit.marksComposition("한글", markedRange: marked, selection: NSRange(location: 5, length: 0)))
    }

    /// A client that reports no mark, or a malformed one, is never written to.
    @Test func anUnknownOrMalformedMarkIsLeftAlone() {
        let caret = NSRange(location: 5, length: 0)
        #expect(!SourceChangeCommit.marksComposition("한", markedRange: NSRange(location: NSNotFound, length: 0), selection: caret))
        #expect(!SourceChangeCommit.marksComposition("한", markedRange: NSRange(location: 5, length: 0), selection: caret))
        #expect(!SourceChangeCommit.marksComposition("한", markedRange: NSRange(location: -1, length: 1), selection: caret))
        #expect(!SourceChangeCommit.marksComposition("한", markedRange: NSRange(location: Int.max, length: 1),
                                                     selection: NSRange(location: NSNotFound, length: 0)))
    }
}
