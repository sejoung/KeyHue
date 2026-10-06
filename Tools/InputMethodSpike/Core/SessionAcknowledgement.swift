
/// Which mode ID the server tells the utility a client session received (ADR 0062).
/// Only the mode ID leaves the server: no client, document or key information.
public enum SessionAcknowledgement {
    /// A session can be told about a selection just before its `deactivateServer`:
    /// the selection notification of a closing session (Latin → ABC → Hangul), or
    /// the activation and mode callback a client sends for another process's
    /// selection and then withdraws (ABC → Hangul routed from the utility, ADR 0070).
    /// The adapter answers this much later, only if the session is still active.
    public static let confirmationDelay: Double = 0.08

    /// The requested ID, not the session mode: a callback can precede TIS
    /// publication, and the key-time check reconciles the mode later.
    /// - Parameter sessionActive: read `confirmationDelay` after the callback.
    public static func forModeCallback(requestedID: String, sessionActive: Bool) -> String? {
        guard sessionActive else { return nil }
        return ProbeSession.Mode(inputSourceID: requestedID) == nil ? nil : requestedID
    }

    /// Selecting between this server's modes from another process reaches an
    /// existing session only as the selection notification, without a callback.
    public static func forSelectionChange(selectedID: String?, sessionActive: Bool, clientIsFront: Bool) -> String? {
        guard sessionActive, clientIsFront, let selectedID,
              ProbeSession.Mode(inputSourceID: selectedID) != nil else { return nil }
        return selectedID
    }
}
