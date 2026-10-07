import AppKit
import InputMethodKit
import KeyHueInputMethodSpikeCore

/// Automatic correction (ADR 0064) for one session: the probe, the keys it sees and
/// the observation that confirms its edits. Only clients routed to `.automatic` use it.
/// All callers already reject non-main-thread IMK callbacks; text edits stay synchronous.
final class SpikeAutomaticCorrection {
    /// Created on first use: most sessions never correct automatically.
    private(set) lazy var probe = IMKCorrectionProbe(sessionComposing: sessionComposing)
    private let sessionID: String
    private let sessionComposing: () -> Bool
    private var eventCount = 0

    init(sessionID: String, sessionComposing: @escaping () -> Bool) {
        self.sessionID = sessionID
        self.sessionComposing = sessionComposing
    }

    private static func selectedMode() -> ProbeSession.Mode? {
        SelectedInputSource.modeID().flatMap(ProbeSession.Mode.init(inputSourceID:))
    }

    /// An actual key or click is about to be processed.
    func interrupt(client: any IMKTextInput) {
        probe.interrupt(client: client, identity: sessionID, currentMode: Self.selectedMode)
    }

    /// Feeds one key. true: Backspace undid a fix; the key is consumed and the
    /// observation that confirms the undo is scheduled.
    func key(_ event: NSEvent, route: InputRoute, mode: ProbeSession.Mode, client: any IMKTextInput,
             isCurrent: @escaping () -> Bool) -> Bool {
        // Per-key diagnostics only for the dedicated host-test bundle, never for real apps.
        if client.bundleIdentifier() == CorrectionRouting.automaticTestClient {
            eventCount += 1
            let kind: String
            switch event.keyCode {
            case 49: kind = "space"
            case 51: kind = "backspace"
            default: if case .compose = route { kind = "letter" } else { kind = "other" }
            }
            SpikeLog.notice("correction probe event session=\(sessionID) ordinal=\(eventCount) kind=\(kind) mode=\(mode.rawValue) selectionLength=\(client.selectedRange().length) markedLength=\(client.markedRange().length)")
        }
        let modifiers = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 49, !modifiers {
            _ = probe.space(client: client, identity: sessionID, mode: mode, currentMode: Self.selectedMode)
        } else if event.keyCode == 51, !modifiers {
            if probe.backspace(client: client, identity: sessionID, currentMode: Self.selectedMode) {
                schedule(client: client, isCurrent: isCurrent)
                return true
            }
        } else if case .compose(let key) = route {
            probe.letter(key, client: client, mode: mode)
        } else {
            probe.invalidate()
        }
        return false
    }

    /// Confirms pending edits on later main-loop turns while the client stays current and in front.
    func schedule(client: any IMKTextInput, isCurrent: @escaping () -> Bool) {
        probe.schedule(client: client, identity: sessionID, currentMode: Self.selectedMode, isCurrent: {
            guard isCurrent(), SelectedInputSource.modeID() != nil else { return false }
            let clientID = client.bundleIdentifier()
            return MainActor.assumeIsolated {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == clientID
            }
        })
    }
}
