import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// One session's word fixing (ADR 0064, 0068): automatic fixes in clients routed
/// to `.automatic`, shortcut fixes in every routed client. A client that is not
/// routed never reaches either adapter.
final class SpikeCorrectionCoordinator {
    /// ADR 0064: automatic fixes, only in clients routed to `.automatic`.
    private let automatic: SpikeAutomaticCorrection
    /// ADR 0068: fixes the user asks for with the shortcut, in every routed client.
    private lazy var shortcut = IMKShortcutCorrection(settings: settings)
    private let settings: SpikeCorrectionSettings
    private var lastMode: CorrectionMode?

    init(sessionID: String, settings: SpikeCorrectionSettings = .shared, sessionComposing: @escaping () -> Bool) {
        automatic = SpikeAutomaticCorrection(sessionID: sessionID, sessionComposing: sessionComposing)
        self.settings = settings
    }

    /// The correction route of this client (ADR 0064). nil: never enters the
    /// correction path. A changed route (setting changed) drops both adapters' state.
    func mode(for client: (any IMKTextInput)?) -> CorrectionMode? {
        let mode = settings.mode(for: client?.bundleIdentifier())
        if mode != lastMode {
            lastMode = mode
            shortcut.interrupt(reason: "settings")
            automatic.probe.invalidateContext()
        }
        return mode
    }

    /// Activation, after the probe was told (`invalidate(.activation)`).
    func activated(client: (any IMKTextInput)?) {
        settings.start()
        switch mode(for: client) {
        case .automatic: automatic.probe.activated(); shortcut.activated()
        case .manual: shortcut.activated()
        case .off, nil: break
        }
    }

    func invalidate(_ reason: ProbeInvalidation = .otherKey) {
        automatic.probe.invalidate(reason)
    }

    /// The input context ended or changed under the session.
    func invalidateContext() {
        automatic.probe.invalidateContext()
    }

    func modeRequested(_ mode: ProbeSession.Mode, client: any IMKTextInput) {
        if self.mode(for: client) == .automatic {
            automatic.probe.modeRequested(mode, client: client)
        }
    }

    /// An actual key or click is about to be processed.
    func eventArrives(client: any IMKTextInput, mode: CorrectionMode?) {
        if mode == .automatic { automatic.interrupt(client: client) }
    }

    func click(mode: CorrectionMode?) {
        automatic.probe.invalidate(.mouse)
        if mode != nil { shortcut.interrupt(reason: "click") }
    }

    /// Terminal fixing's own Backspaces pass to the client untouched (ADR 0067).
    func passesPostedKey(_ event: NSEvent, modifiers: Bool, mode: CorrectionMode?) -> Bool {
        mode != nil && shortcut.postedKeyArrived(event, modifiers: modifiers)
    }

    /// Asked once the session has its mode for the key.
    func steps(for event: NSEvent, mode: CorrectionMode?) -> CorrectionKeySteps {
        // A password prompt is never fixed and its keys are not remembered.
        let secureInput = mode != nil && IsSecureEventInputEnabled()
        let steps = CorrectionKeySteps(mode: mode, secureInput: secureInput, isShortcut: mode != nil && shortcut.isShortcut(event))
        if steps.shortcut == .skippedForSecureInput {
            SpikeLog.notice("shortcut correction skipped reason=secureInput")
        }
        return steps
    }

    /// The shortcut, after its composition was committed.
    func requestFix(client: any IMKTextInput, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) {
        automatic.probe.invalidate(.shortcut)
        shortcut.request(client: client, mode: mode, isCurrent: isCurrent)
    }

    /// Any other key, before the session handles it. true: automatic correction
    /// consumed it (Backspace undid a fix).
    /// - Parameter otherModifiers: ⌘·⌃·⌥.
    func key(_ route: InputRoute, event: NSEvent, otherModifiers: Bool, steps: CorrectionKeySteps, composing: Bool,
             client: any IMKTextInput, mode: ProbeSession.Mode, isCurrent: @escaping () -> Bool) -> Bool {
        switch steps.tracking {
        case .track:
            shortcut.key(route, keyCode: event.keyCode, modifiers: otherModifiers, shift: event.modifierFlags.contains(.shift),
                         text: event.characters, composing: composing, client: client, mode: mode)
        case .interrupt:
            shortcut.interrupt(reason: "secure input")
        case .none:
            break
        }
        // Unrouted clients use exactly the existing composition path.
        return steps.automatic && automatic.key(route: route, mode: mode, client: client, isCurrent: isCurrent)
    }

    /// Confirms automatic edits after the session handled the key.
    func keyHandled(client: any IMKTextInput, mode: CorrectionMode?, isCurrent: @escaping () -> Bool) {
        if mode == .automatic { automatic.schedule(client: client, isCurrent: isCurrent) }
    }
}
