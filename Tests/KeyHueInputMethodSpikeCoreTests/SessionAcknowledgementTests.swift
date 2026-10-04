import Testing
import KeyHueCore
@testable import KeyHueInputMethodSpikeCore

/// The utility repairs a session only when the server stays silent (ADR 0062), so
/// every path where a client session already receives the selection must answer.
struct SessionAcknowledgementTests {
    /// A callback can arrive before TIS publishes the selection; the request is the answer.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func modeCallbackAcknowledgesTheRequestedMode(_ id: String) {
        #expect(SessionAcknowledgement.forModeCallback(requestedID: id) == id)
    }

    @Test(arguments: [InputMethodIntegration.abcID, ""])
    func modeCallbackForAnotherSourceIsNotAnAcknowledgement(_ id: String) {
        #expect(SessionAcknowledgement.forModeCallback(requestedID: id) == nil)
    }

    /// Switching between this server's own modes from another process delivers
    /// no callback, only the selection notification to the active session.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func activeFrontSessionAcknowledgesASelectionChange(_ id: String) {
        #expect(SessionAcknowledgement.forSelectionChange(selectedID: id, sessionActive: true, clientIsFront: true) == id)
    }

    @Test func inactiveSessionDoesNotAcknowledge() {
        #expect(SessionAcknowledgement.forSelectionChange(selectedID: InputMethodIntegration.hangulID,
                                                          sessionActive: false, clientIsFront: true) == nil)
    }

    /// A session left in a background app says nothing about the front client.
    @Test func backgroundSessionDoesNotAcknowledge() {
        #expect(SessionAcknowledgement.forSelectionChange(selectedID: InputMethodIntegration.hangulID,
                                                          sessionActive: true, clientIsFront: false) == nil)
    }

    @Test(arguments: [Optional<String>.none, InputMethodIntegration.abcID])
    func selectionOfAnotherSourceDoesNotAcknowledge(_ id: String?) {
        #expect(SessionAcknowledgement.forSelectionChange(selectedID: id, sessionActive: true, clientIsFront: true) == nil)
    }
}
