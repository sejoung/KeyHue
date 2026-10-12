import KeyHueCore

/// Which correction steps a key goes through once the session has its mode
/// (ADR 0064, 0068). An unrouted client (`mode == nil`) goes through none.
public struct CorrectionKeySteps: Equatable, Sendable {
    public enum Shortcut: Equatable, Sendable {
        case none
        /// The composition is committed, the key consumed and a fix requested.
        case requestFix
        /// A password prompt is never fixed: the shortcut goes to the app as usual.
        case skippedForSecureInput
    }

    /// What the shortcut correction does with any other key.
    public enum Tracking: Equatable, Sendable {
        case none
        /// Follows the key (a terminal's typed word).
        case track
        /// Secure input: its keys are not remembered and the word before them is unknown.
        case interrupt
    }

    public let shortcut: Shortcut
    public let tracking: Tracking
    /// The automatic correction sees the key; it checks secure input itself.
    public let automatic: Bool

    /// - Parameters:
    ///   - secureInput: secure event input is on.
    ///   - isShortcut: the key is the correction shortcut.
    public init(mode: CorrectionMode?, secureInput: Bool, isShortcut: Bool) {
        let secure = mode != nil && secureInput
        let handlesShortcut = CorrectionRouting.handlesShortcut(mode: mode, secureInput: secure)
        if isShortcut, handlesShortcut {
            shortcut = .requestFix
        } else if isShortcut, secure {
            shortcut = .skippedForSecureInput
        } else {
            shortcut = .none
        }
        tracking = handlesShortcut ? .track : secure ? .interrupt : .none
        automatic = mode == .automatic
    }
}
