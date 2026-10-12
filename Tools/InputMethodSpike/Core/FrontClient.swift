/// Whether a client is the front app. Edits and acknowledgements go only to the
/// app in front; a client without a bundle ID is never taken for it.
public enum FrontClient {
    public static func matches(clientID: String?, frontID: String?) -> Bool {
        guard let clientID, !clientID.isEmpty else { return false }
        return clientID == frontID
    }
}
