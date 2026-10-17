import Foundation

/// macOS's input source switcher (TextInputSwitcher) sometimes switches twice for one
/// ⌘Space: KeyHue English → Korean → English 20–50 ms apart, right after ⌘ is released,
/// with no key in between (2026-10-17 09:08:38–09:24:02, Chrome and Ghostty). The press
/// seems to do nothing. The source the press chose is selected again (ADR 0091).
///
/// Only between the two KeyHue modes, and only when the change back comes within
/// `reversal` of the first and `modifierLead` of a modifier key change (⌘Space and
/// Caps Lock switch on a modifier's release). A key, a click or KeyHue's own selection
/// in between makes the second change someone's choice.
public struct DoubleSwitchDetector: Sendable {
    /// Observed 17–46 ms. No person switches twice in this time.
    public static let reversal: TimeInterval = 0.1
    /// The switch follows the modifier's release by about 20 ms.
    public static let modifierLead: TimeInterval = 0.5

    private struct Change: Sendable {
        let from: String
        let to: String
        let time: TimeInterval
    }

    private var current: String?
    private var lastChange: Change?
    private var modifierTime: TimeInterval?

    public init() {}

    /// A new baseline: app activation, window or focus change.
    public mutating func reset(current id: String?) {
        current = id
        lastChange = nil
    }

    /// A modifier key (⌘, Caps Lock, …) went down or up.
    /// - Parameter time: a monotonic clock, in seconds.
    public mutating func modifierChanged(at time: TimeInterval) {
        modifierTime = time
    }

    /// A key, a click or KeyHue's own selection.
    public mutating func interrupt() {
        lastChange = nil
        modifierTime = nil
    }

    /// Invoke for selected-source notifications.
    /// - Parameter time: a monotonic clock, in seconds.
    /// - Returns: the source to select again when this change undid the previous one.
    public mutating func selected(sourceID id: String?, at time: TimeInterval) -> String? {
        let old = current
        current = id
        guard let id, let old, id != old else { return nil }
        if let change = lastChange, change.from == id, change.to == old, time - change.time <= Self.reversal,
           let modifier = modifierTime, time - modifier <= Self.modifierLead {
            interrupt()
            return change.to
        }
        let betweenModes = InputMethodIntegration.isMode(old) && InputMethodIntegration.isMode(id)
        lastChange = betweenModes ? Change(from: old, to: id, time: time) : nil
        return nil
    }
}
