import Foundation

/// Observes actual source transitions rather than mapping switching shortcuts.
/// Does not synthesize keys, edit text, or retry failed selections; the separate
/// session repair may press the user's own switching shortcut (ADR 0062). OS notification
/// timing is still a manual compatibility gate, not a guarantee of first-key delivery.
///
/// A detour (ABC, the system 2-Set Korean) chosen from a KeyHue mode is routed to the
/// other KeyHue mode (ADR 0071, 0082). One the system chose itself (the lock screen, a
/// password field) is not routed; once it gives way, the order of the previous sources
/// is fixed instead.
@MainActor
public final class InputMethodRoutingCoordinator {
    private let switcher: InputSourceSwitching
    private let scheduler: Scheduling
    private let isEnabled: () -> Bool
    private var previousID: String?
    private var generation = 0
    private var bounceGeneration = 0
    private var protectedTarget: String?
    /// The mode being left, selected just before the target (ADR 0071).
    private var protectedLeaving: String?
    public private(set) var isPending = false
    /// A detour the system selected without a route. It stays the previous source,
    /// so ⌘Space goes back to it, until the order is fixed (ADR 0082).
    private var systemDetour = false
    /// The KeyHue mode left for it, when KeyHue saw the change (nil after a relaunch on the lock screen).
    private var systemDetourLeft: String?
    public var onRequest: (() -> Void)?
    public var onCompletion: ((Bool) -> Void)?
    /// The system's detour was moved behind the two KeyHue modes.
    public var onSystemDetourCleared: ((Bool) -> Void)?
    /// Caller turns off only the experimental routing option; normal integration remains usable.
    public var onSuspend: (() -> Void)?

    public init(switcher: InputSourceSwitching, scheduler: Scheduling, isEnabled: @escaping () -> Bool) {
        self.switcher = switcher
        self.scheduler = scheduler
        self.isEnabled = isEnabled
    }

    /// A new baseline: startup, app activation, window or focus change.
    public func reset(current: InputSourceInfo?) {
        cancel()
        previousID = current?.id
        clearBounceProtection()
        guard let id = current?.id, InputMethodIntegration.detourIDs.contains(id), isAvailable else { return }
        if !isEnabled() {
            // Started or re-based while the lock screen or a password field holds it.
            systemDetour = true
        } else if systemDetour {
            // 2026-10-07 18:17: ABC was still selected after the unlock. Return to the mode it left.
            reorder(ending: systemDetourLeft ?? InputMethodIntegration.latinID, whileCurrent: id)
        }
    }

    public func interaction(isTyping: Bool) {
        clearBounceProtection()
        if isTyping {
            cancel()
            // A key can arrive after the OS switch but before its distributed notification.
            // Rebase on TIS now so a late notification cannot change mode mid-word.
            previousID = switcher.currentSource?.id
        }
    }

    /// Invoke for selected-source notifications only. Startup, roster changes,
    /// app activation and explicit utility actions establish a new baseline instead.
    public func sourceChanged(to source: InputSourceInfo?) {
        let old = previousID
        previousID = source?.id
        // Before the duplicate check: a baseline reset can already have read the restored mode.
        if systemDetour, let id = source?.id, Self.isMode(id), isEnabled(), isAvailable {
            // 2026-10-07 17:40: macOS put KeyHue English back after the unlock and ABC
            // stayed the previous source. Select the other mode, then this one again.
            reorder(ending: id, whileCurrent: id)
            return
        }
        guard old != source?.id else { return }
        cancel()
        guard let detour = source?.id, InputMethodIntegration.detourIDs.contains(detour), isAvailable else {
            if source?.id != protectedTarget && source?.id != protectedLeaving { clearBounceProtection() }
            return
        }
        guard isEnabled() else {
            systemDetour = true
            if let old, Self.isMode(old) { systemDetourLeft = old }
            if source?.id != protectedTarget && source?.id != protectedLeaving { clearBounceProtection() }
            return
        }
        // A route selects both modes: the detour is no longer the previous source afterwards.
        systemDetour = false
        systemDetourLeft = nil
        guard let leaving = old, Self.isMode(leaving) else { return }
        let target = Self.other(leaving)
        // An immediate return to a detour after our own selection can be a TSM overwrite.
        // Suspend rather than oscillating. A fresh key/menu interaction clears this guard.
        if old == protectedTarget || old == protectedLeaving {
            clearBounceProtection()
            onSuspend?()
            return
        }
        isPending = true
        let request = generation
        onRequest?()
        scheduler.schedule(after: 0) { [weak self] in
            guard let self, self.generation == request, self.isPending else { return }
            self.isPending = false
            guard self.isEnabled(), self.isAvailable, self.switcher.currentSource?.id == detour else { return }
            self.protectedTarget = target
            self.protectedLeaving = leaving
            self.bounceGeneration += 1
            let protection = self.bounceGeneration
            // "Select the previous input source" (⌘Space) goes back to the source
            // selected before the current one. Selecting the mode being left first
            // makes it, not the detour, the previous source: the next press toggles the
            // two modes inside the client instead of routing through the detour and
            // another external selection, which a client can close at once (ADR 0071).
            _ = self.switcher.perform(.select(sourceID: leaving))
            // Right after two selections TIS can still report the first one; that is not a
            // failure (2026-10-06 14:05:15 turned routing off). An overwrite back to the detour
            // is caught by the protection below (ADR 0077).
            let ok = self.switcher.perform(.select(sourceID: target))
            self.previousID = self.switcher.currentSource?.id
            if !ok {
                self.clearBounceProtection()
                self.onSuspend?()
            } else {
                self.scheduler.schedule(after: 0.2) { [weak self] in
                    guard let self, self.bounceGeneration == protection else { return }
                    self.clearBounceProtection()
                }
            }
            self.onCompletion?(ok)
        }
    }

    private var isAvailable: Bool { InputMethodIntegration.isAvailable(in: switcher.availableSources) }

    private static func isMode(_ id: String) -> Bool {
        id == InputMethodIntegration.hangulID || id == InputMethodIntegration.latinID
    }

    private static func other(_ mode: String) -> String {
        mode == InputMethodIntegration.hangulID ? InputMethodIntegration.latinID : InputMethodIntegration.hangulID
    }

    /// Selects the other mode, then `mode`, as a route does: ⌘Space then toggles the
    /// two KeyHue modes. Runs on the next turn unless a key or a newer change comes first.
    private func reorder(ending mode: String, whileCurrent expected: String) {
        cancel()
        isPending = true
        let request = generation
        onRequest?()
        scheduler.schedule(after: 0) { [weak self] in
            guard let self, self.generation == request, self.isPending else { return }
            self.isPending = false
            guard self.isEnabled(), self.switcher.currentSource?.id == expected else { return }
            self.systemDetour = false
            self.systemDetourLeft = nil
            _ = self.switcher.perform(.select(sourceID: Self.other(mode)))
            let ok = self.switcher.perform(.select(sourceID: mode))
            self.previousID = self.switcher.currentSource?.id
            self.onSystemDetourCleared?(ok)
        }
    }

    private func cancel() {
        generation += 1
        isPending = false
    }

    private func clearBounceProtection() {
        bounceGeneration += 1
        protectedTarget = nil
        protectedLeaving = nil
    }
}
