import KeyHueCore
import Testing
@testable import KeyHueInputMethodSpikeCore

/// ADR 0065: at the manual correction's deadline, decide whether the app failed.
/// The user changing the text or caret first is not an app failure.
@Suite("Correction result check")
struct CorrectionResultCheckTests {
    @Test func anAppThatCannotReportTextFails() {
        #expect(CorrectionResultCheck.failure(afterRequest: false, textAvailable: false, originalStillThere: false) == .textUnavailable)
        #expect(CorrectionResultCheck.failure(afterRequest: true, textAvailable: false, originalStillThere: false) == .textUnavailable)
    }

    @Test func theUserChangingTextBeforeTheRequestIsNotAFailure() {
        #expect(CorrectionResultCheck.failure(afterRequest: false, textAvailable: true, originalStillThere: false) == nil)
        #expect(CorrectionResultCheck.failure(afterRequest: false, textAvailable: true, originalStillThere: true) == nil)
    }

    @Test func anIgnoredReplacementLeavesTheOriginal() {
        #expect(CorrectionResultCheck.failure(afterRequest: true, textAvailable: true, originalStillThere: true) == .replacementIgnored)
    }

    @Test func anythingElseAfterTheRequestIsUnexpected() {
        #expect(CorrectionResultCheck.failure(afterRequest: true, textAvailable: true, originalStillThere: false) == .unexpectedResult)
    }
}
