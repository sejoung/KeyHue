import Foundation

/// When to tell the user that another app's secure input keeps KeyHue's modes from
/// being selected (ADR 0095). While any process holds secure event input, macOS puts ABC
/// back over a third-party input method in every app, and ⌘Space only toggles the system
/// sources (2026-11-18 13:04–13:12: Chrome held it from the background for 8 minutes).
///
/// - The front app's own password field is expected to select ABC: no notice.
/// - The lock screen selects ABC itself: no notice.
/// - Once per holder until secure input is seen off, and not again within `minimumInterval`.
public struct SecureInputNoticePolicy: Sendable {
    /// Source changes come in bursts while macOS overwrites a selection; wait for the last one.
    public static let settleDelay: TimeInterval = 0.3
    /// An app that takes and releases secure input on every switch is not announced each time.
    public static let minimumInterval: TimeInterval = 30
    /// Longer than a fix notice: the caption says what to do.
    public static let holdDuration: TimeInterval = 4

    public struct Situation: Equatable, Sendable {
        public var integrated: Bool
        public var currentIsDetour: Bool
        public var holderPID: Int32?
        public var frontPID: Int32?
        public var frontIsLoginWindow: Bool

        public init(integrated: Bool, currentIsDetour: Bool, holderPID: Int32?, frontPID: Int32?, frontIsLoginWindow: Bool) {
            self.integrated = integrated
            self.currentIsDetour = currentIsDetour
            self.holderPID = holderPID
            self.frontPID = frontPID
            self.frontIsLoginWindow = frontIsLoginWindow
        }
    }

    private var announcedHolder: Int32?
    private var lastShown: TimeInterval?

    public init() {}

    /// Whether secure input held by another app is what keeps a detour selected now.
    public static func blocksKeyHue(_ situation: Situation) -> Bool {
        guard situation.integrated, situation.currentIsDetour, !situation.frontIsLoginWindow,
              let holder = situation.holderPID else { return false }
        return holder != situation.frontPID
    }

    /// Secure input was seen off: the next hold is announced again (after `minimumInterval`).
    public mutating func secureInputEnded() {
        announcedHolder = nil
    }

    /// true: show the notice now. Records it as shown.
    public mutating func shouldShow(_ situation: Situation, now: TimeInterval) -> Bool {
        guard Self.blocksKeyHue(situation), let holder = situation.holderPID, holder != announcedHolder else { return false }
        if let lastShown, now - lastShown < Self.minimumInterval { return false }
        announcedHolder = holder
        lastShown = now
        return true
    }
}
