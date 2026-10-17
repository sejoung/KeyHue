import KeyHueCore

/// ADR 0066: some clients send the text committed during a key together with that
/// key, and their encoding of Tab and navigation keys drops the text (Ghostty 1.3.1,
/// ghostty-org/ghostty#11461; the system Korean input method loses it the same way).
/// There the composition is committed after the key instead: the key is consumed
/// and the text is delivered on its own, so the last character is never lost.
public enum DetachedCommit {
    public static let clients: Set<String> = ["com.mitchellh.ghostty"]
    /// Tab, arrows, Home, End, Page Up/Down and forward Delete. Return and Escape
    /// keep the committed text in these clients, and text keys carry their own.
    static let keyCodes: Set<UInt16> = [KeyCode.tab, KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow,
                                        KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown, KeyCode.forwardDelete]

    /// - Parameter otherModifiers: ⌘·⌃·⌥. A shortcut always reaches the app.
    public static func applies(clientID: String?, keyCode: UInt16, otherModifiers: Bool) -> Bool {
        guard let clientID, clients.contains(clientID), !otherModifiers else { return false }
        return keyCodes.contains(keyCode)
    }

    /// The key would end a composition there and drop it: the key is consumed and
    /// the commit held until it has finished (`HeldCommit`).
    public static func holdsCommit(detached: Bool, route: InputRoute, composing: Bool) -> Bool {
        detached && route == .commitAndPass && composing
    }

    /// Marked while a consumed key is handled (zero width, never committed).
    public static let placeholder = "\u{200B}"

    /// ADR 0092: Chromium browsers send the page the key the input method consumed
    /// unless a composition is left when the key ends. A fix replaces the word only
    /// after the key, so ⌥↩ reached the page as Return and ran a Google search
    /// (2026-10-17 09:33:24–52).
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser", "com.naver.Whale",
    ]

    /// ADR 0068: these clients send a key the input method consumed unless text
    /// is composing, so the correction shortcut would reach the program. With
    /// nothing committed, a placeholder is marked for the key (`now`) and cleared
    /// once the key has finished there (`after`). A browser gets it after the
    /// committed text too: committing ends the composition (ADR 0092).
    public static func consume(clientID: String?, committed: [ProbeSession.Action])
        -> (now: [ProbeSession.Action], after: [ProbeSession.Action]) {
        guard let clientID else { return (committed, []) }
        if browsers.contains(clientID) { return (committed + [.mark(placeholder)], [.mark("")]) }
        guard clients.contains(clientID), committed.isEmpty else { return (committed, []) }
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
