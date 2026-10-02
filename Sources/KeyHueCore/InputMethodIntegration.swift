import Foundation

/// Only the installed spike's two explicit TIS mode IDs are recognized. A future
/// production input method must opt into this contract separately (ADR 0049).
public enum InputMethodIntegration {
    public static let abcID = "com.apple.keylayout.ABC"
    public static let hangulID = "io.github.sejoung.keyhue.inputmethod.spike.Hangul"
    public static let latinID = "io.github.sejoung.keyhue.inputmethod.spike.Latin"

    public static func isAvailable(in sources: [InputSourceInfo]) -> Bool {
        let ids = Set(sources.map(\.id))
        return ids.contains(hangulID) && ids.contains(latinID)
    }

    public static func sourceID(_ id: String, settings: KeyHueSettings, sources: [InputSourceInfo]) -> String {
        settings.integrateInputMethod && isAvailable(in: sources) && id == abcID ? latinID : id
    }

    /// Effective settings are a copy: disabling integration restores the saved preference.
    public static func effectiveSettings(_ settings: KeyHueSettings, sources: [InputSourceInfo]) -> KeyHueSettings {
        guard settings.integrateInputMethod, isAvailable(in: sources) else { return settings }
        var result = settings
        if settings.defaultSourceID == nil || settings.defaultSourceID == abcID {
            result.defaultSourceID = latinID
        }
        return result
    }

    public static func automaticSource(settings: KeyHueSettings, sources: [InputSourceInfo]) -> InputSourceInfo? {
        var automatic = settings
        automatic.defaultSourceID = nil
        return defaultSource(settings: automatic, sources: sources)
    }

    public static func defaultSource(settings: KeyHueSettings, sources: [InputSourceInfo]) -> InputSourceInfo? {
        DefaultInputSourcePicker.pick(from: sources, preferredID: effectiveSettings(settings, sources: sources).defaultSourceID)
    }
}

/// Observes actual source transitions rather than mapping switching shortcuts.
/// Does not synthesize keys, edit text, or retry failed selections. OS notification
/// timing is still a manual compatibility gate, not a guarantee of first-key delivery.
@MainActor
public final class InputMethodRoutingCoordinator {
    private let switcher: InputSourceSwitching
    private let scheduler: Scheduling
    private let isEnabled: () -> Bool
    private var previousID: String?
    private var generation = 0
    private var bounceGeneration = 0
    private var protectedTarget: String?
    public private(set) var isPending = false
    public var onRequest: (() -> Void)?
    public var onCompletion: ((Bool) -> Void)?
    /// Caller turns off only the experimental routing option; normal integration remains usable.
    public var onSuspend: (() -> Void)?

    public init(switcher: InputSourceSwitching, scheduler: Scheduling, isEnabled: @escaping () -> Bool) {
        self.switcher = switcher
        self.scheduler = scheduler
        self.isEnabled = isEnabled
    }

    public func reset(current: InputSourceInfo?) {
        cancel()
        previousID = current?.id
        clearBounceProtection()
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
        guard old != source?.id else { return }
        cancel()
        guard isEnabled(), InputMethodIntegration.isAvailable(in: switcher.availableSources),
              source?.id == InputMethodIntegration.abcID else {
            if source?.id != protectedTarget { clearBounceProtection() }
            return
        }
        let target: String
        switch old {
        case InputMethodIntegration.hangulID: target = InputMethodIntegration.latinID
        case InputMethodIntegration.latinID: target = InputMethodIntegration.hangulID
        default: return
        }
        // An immediate return to ABC after our own selection can be a TSM overwrite.
        // Suspend rather than oscillating. A fresh key/menu interaction clears this guard.
        if old == protectedTarget {
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
            guard self.isEnabled(), InputMethodIntegration.isAvailable(in: self.switcher.availableSources),
                  self.switcher.currentSource?.id == InputMethodIntegration.abcID else { return }
            self.protectedTarget = target
            self.bounceGeneration += 1
            let protection = self.bounceGeneration
            let ok = self.switcher.perform(.select(sourceID: target))
                && self.switcher.currentSource?.id == target
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

    private func cancel() {
        generation += 1
        isPending = false
    }

    private func clearBounceProtection() {
        bounceGeneration += 1
        protectedTarget = nil
    }
}
