/// ADR 0090: some clients end the input context inside one of our edits and open it
/// again with the next key (ChatGPT while editing a message, 2026-10-12). Committing
/// the composition there splits the syllable that follows: 가 + ㄴ + ㅏ commits 가,
/// the deactivation commits 나, and the next ㄴ cannot make 난.
/// The composition is kept instead, and committed only if the client stays closed.
public enum ReentrantDeactivation {
    /// How long a kept composition waits for the client to open the context again.
    /// Longer than a pause between keys inside a word.
    public static let commitDelay: Double = 2

    /// - Parameters:
    ///   - duringDelivery: the deactivation arrived inside one of our edits to the client.
    ///   - composing: the session still has a composition the client has not received yet.
    /// - Returns: true to keep the composition instead of committing it.
    public static func keepsComposition(duringDelivery: Bool, composing: Bool) -> Bool {
        duringDelivery && composing
    }
}
