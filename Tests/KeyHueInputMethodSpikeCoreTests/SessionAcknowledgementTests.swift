import Testing
import KeyHueCore
@testable import KeyHueInputMethodSpikeCore

/// The utility repairs a session only when the server stays silent (ADR 0062), so
/// every path where a client session already receives the selection must answer.
struct SessionAcknowledgementTests {
    /// A callback can arrive before TIS publishes the selection; the request is the answer.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func modeCallbackAcknowledgesTheRequestedMode(_ id: String) {
        #expect(SessionAcknowledgement.forModeCallback(requestedID: id, sessionActive: true) == id)
    }

    @Test(arguments: [InputMethodIntegration.abcID, ""])
    func modeCallbackForAnotherSourceIsNotAnAcknowledgement(_ id: String) {
        #expect(SessionAcknowledgement.forModeCallback(requestedID: id, sessionActive: true) == nil)
    }

    /// Ghostty, ABC → Hangul routed by the utility: activation and mode callback,
    /// then `deactivateServer` 1ms later. The menu bar showed Hangul, keys stayed
    /// raw, and the immediate acknowledgement had skipped the repair (ADR 0070).
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func callbackOfASessionClosedSinceIsNotAnAcknowledgement(_ id: String) {
        #expect(SessionAcknowledgement.forModeCallback(requestedID: id, sessionActive: false) == nil)
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

    /// A source change through ABC deactivates the session, but the selection
    /// notification can arrive just before `deactivateServer`. Acknowledged at
    /// once, the closing session told the utility the new mode had a session, the
    /// repair was skipped and the window typed raw ASCII. The acknowledgement waits
    /// for that callback, well inside the utility's window.
    @MainActor
    @Test func acknowledgementsWaitForPendingDeactivation() {
        #expect(SessionAcknowledgement.confirmationDelay >= 0.05)
        #expect(SessionAcknowledgement.confirmationDelay * 2 <= InputMethodSessionRepair.acknowledgementTimeout)
    }
}

/// 2026-10-07 14:02:43, Chrome: KeyHue switched to English, the first key reached
/// the session and synchronized it, then Chrome closed the session for a focus move
/// before the mode callback's confirmation. The utility heard nothing and pressed
/// the previous-source shortcut twice while the user typed. A key in a session is
/// the surest confirmation: answered once per session and mode.
struct KeyAcknowledgementTests {
    @Test func firstKeyInEachModeIsAnAcknowledgement() {
        var acknowledgement = KeyAcknowledgement()
        #expect(acknowledgement.key(in: .latin) == InputMethodIntegration.latinID)
        #expect(acknowledgement.key(in: .latin) == nil)
        #expect(acknowledgement.key(in: .hangul) == InputMethodIntegration.hangulID)
        #expect(acknowledgement.key(in: .hangul) == nil)
        #expect(acknowledgement.key(in: .latin) == InputMethodIntegration.latinID)
    }

    /// A new activation may follow KeyHue's next selection: answer its first key again.
    @Test func activationAnswersAgain() {
        var acknowledgement = KeyAcknowledgement()
        _ = acknowledgement.key(in: .hangul)
        acknowledgement.reset()
        #expect(acknowledgement.key(in: .hangul) == InputMethodIntegration.hangulID)
    }
}
