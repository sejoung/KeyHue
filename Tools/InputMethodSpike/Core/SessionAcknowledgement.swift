import KeyHueCore

/// Which mode ID the server tells the utility a client session received (ADR 0062).
/// Only the mode ID leaves the server: no client, document or key information.
public enum SessionAcknowledgement {
    /// The requested ID, not the session mode: a callback can precede TIS
    /// publication, and the key-time check reconciles the mode later.
    public static func forModeCallback(requestedID: String) -> String? {
        ProbeSession.Mode(inputSourceID: requestedID) == nil ? nil : requestedID
    }

    /// Selecting between this server's modes from another process reaches an
    /// existing session only as the selection notification, without a callback.
    public static func forSelectionChange(selectedID: String?, sessionActive: Bool, clientIsFront: Bool) -> String? {
        guard sessionActive, clientIsFront, let selectedID,
              ProbeSession.Mode(inputSourceID: selectedID) != nil else { return nil }
        return selectedID
    }
}
