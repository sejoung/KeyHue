/// ADR 0066: some clients send the text committed during a key together with that
/// key, and their encoding of Tab and navigation keys drops the text (Ghostty 1.3.1,
/// ghostty-org/ghostty#11461; the system Korean input method loses it the same way).
/// There the composition is committed after the key instead: the key is consumed
/// and the text is delivered on its own, so the last character is never lost.
public enum DetachedCommit {
    public static let clients: Set<String> = ["com.mitchellh.ghostty"]
    /// Tab, arrows, Home, End, Page Up/Down and forward Delete. Return and Escape
    /// keep the committed text in these clients, and text keys carry their own.
    static let keyCodes: Set<UInt16> = [48, 123, 124, 125, 126, 115, 119, 116, 121, 117]

    /// - Parameter otherModifiers: ⌘·⌃·⌥. A shortcut always reaches the app.
    public static func applies(clientID: String?, keyCode: UInt16, otherModifiers: Bool) -> Bool {
        guard let clientID, clients.contains(clientID), !otherModifiers else { return false }
        return keyCodes.contains(keyCode)
    }

    /// Marked while a consumed key is handled (zero width, never committed).
    public static let placeholder = "\u{200B}"

    /// ADR 0068: these clients send a key the input method consumed unless text
    /// is composing, so the correction shortcut would reach the program. With
    /// nothing committed, a placeholder is marked for the key (`now`) and cleared
    /// once the key has finished there (`after`).
    public static func consume(clientID: String?, committed: [ProbeSession.Action])
        -> (now: [ProbeSession.Action], after: [ProbeSession.Action]) {
        guard let clientID, clients.contains(clientID), committed.isEmpty else { return (committed, []) }
        return ([.mark(placeholder)], [.mark("")])
    }
}

/// The commit held until the consuming key has finished in the client.
public struct HeldCommit: Sendable {
    public private(set) var actions: [ProbeSession.Action] = []
    public var isEmpty: Bool { actions.isEmpty }

    public init() {}

    public mutating func hold(_ more: [ProbeSession.Action]) {
        actions += more
    }

    public mutating func take() -> [ProbeSession.Action] {
        defer { actions = [] }
        return actions
    }

    /// A key that arrives before the held text was delivered. A text key delivers it
    /// first and keeps the order. A detached key would drop it again, so that key is
    /// consumed and the text stays held for its own delivery.
    public mutating func beforeKey(detached: Bool) -> (deliver: [ProbeSession.Action], consumeKey: Bool) {
        guard !isEmpty else { return ([], false) }
        return detached ? ([], true) : (take(), false)
    }
}
