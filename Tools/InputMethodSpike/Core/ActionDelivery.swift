/// ADR 0086: a client can end the composition while it handles one of our edits
/// (Fork deactivated the server inside `insertText`). Once the session's composition
/// is committed, a mark still waiting in the same action list shows a composition
/// that is no longer the session's: it would appear twice, and the next key would
/// replace it instead of composing with it. A deactivation inside an edit now keeps
/// the composition (ADR 0090); a commit or cancel request there still ends it.
public enum ActionDelivery {
    /// Delivers `actions` in order. Once `compositionEnded()` reports that the
    /// session's composition ended during an earlier action, the remaining marks are
    /// skipped. Commits are still delivered: that text exists nowhere else.
    /// - Returns: the number of skipped marks.
    @discardableResult
    public static func deliver(_ actions: [ProbeSession.Action], compositionEnded: () -> Bool,
                               _ perform: (ProbeSession.Action) -> Void) -> Int {
        var skipped = 0
        for action in actions {
            if case .mark = action, compositionEnded() {
                skipped += 1
                continue
            }
            perform(action)
        }
        return skipped
    }
}
