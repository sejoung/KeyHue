import AppKit
import KeyHueCore

/// The input method session repair wired to the real front app and shortcut.
/// The app and the opt-in acceptance worker share this one setup (ADR 0062).
@MainActor
enum SystemSessionRepair {
    /// - Parameter serverNeedsUpdate: the installed server predates this app. An
    ///   older server may not acknowledge sessions at all, so its silence would
    ///   wrongly mark every app unrepaired (ADR 0070).
    static func make(poster: InputSourceShortcutPoster, scheduler: Scheduling = MainQueueScheduler(),
                     serverNeedsUpdate: @escaping @MainActor () -> Bool = { false }) -> InputMethodSessionRepair {
        InputMethodSessionRepair(
            scheduler: scheduler,
            canRepair: {
                if serverNeedsUpdate() {
                    Log.state.notice("input method session repair skipped: installed input method needs update")
                    return false
                }
                guard let reason = poster.unavailableReason else { return true }
                Log.state.notice("input method session repair skipped: \(reason)")
                return false
            },
            currentContext: {
                // Never repair while KeyHue itself is in front (settings window).
                guard let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                return AnyHashable(front.processIdentifier)
            },
            pressShortcut: { poster.press() }
        )
    }
}
