import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// What this server shows a client and logs about it.
enum SpikeClientText {
    /// The composing character with an underline, as the system input methods mark it.
    /// A plain string leaves the look to the app, and many apps (AppKit's default marked
    /// text attributes among them) draw it like a selection (2026-10-06, ADR 0048).
    static func markedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .markedClauseSegment: 0
        ])
    }

    /// Marks or commits in the client. `compositionEnded`: whether the session's
    /// composition ended while the actions were delivered (ADR 0086). `observeMarked`:
    /// whether the client reported the composition just marked.
    /// - Returns: the number of skipped marks.
    @discardableResult
    static func apply(_ actions: [ProbeSession.Action], to client: any IMKTextInput,
                      compositionEnded: () -> Bool, observeMarked: (Bool) -> Void) -> Int {
        ActionDelivery.deliver(actions, compositionEnded: compositionEnded) { action in
            switch action {
            case .mark(let text):
                client.setMarkedText(markedText(text), selectionRange: NSRange(location: text.utf16.count, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                observeMarked(!text.isEmpty && client.markedRange().length > 0)
            case .commit(let text):
                // IMKTextInput specifies NSNotFound for both components when
                // inserting at the current selection/inline composition.
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            }
        }
    }

    /// Only the client's bundle ID enters the log, never its document state.
    static func clientName(_ client: (any IMKTextInput)?) -> String {
        guard let id = client?.bundleIdentifier(), !id.isEmpty else { return "unknown" }
        return id
    }
}

/// The input source the system has selected, read from TIS.
enum SelectedInputSource {
    /// This server's mode ID when one of its modes is selected.
    static func modeID() -> String? {
        guard let id = sourceID(), ProbeSession.Mode(inputSourceID: id) != nil else { return nil }
        return id
    }

    static func sourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func string(_ key: CFString) -> String? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        // The selected source ID is authoritative when present. Do not reinterpret
        // another input source using a stale mode property from this server.
        if let id = string(kTISPropertyInputSourceID) {
            if id != SpikeMetadata.bundleID { return id }
        }
        guard let id = string(kTISPropertyInputModeID), ProbeSession.Mode(inputSourceID: id) != nil else { return nil }
        return id
    }
}

/// Tells the utility that a client session reached this server (ADR 0062). Only
/// the mode ID is sent: no client, document or key information.
enum SessionAcknowledgementPoster {
    static func post(_ modeID: String?) {
        guard let modeID else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(InputMethodIntegration.sessionAcknowledgement), object: modeID,
            userInfo: nil, deliverImmediately: true)
    }

    /// A selection between this server's modes reached a session without a mode callback.
    static func postSelectionChange(sessionActive: Bool, clientID: String?) {
        let frontID = MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        post(SessionAcknowledgement.forSelectionChange(
            selectedID: SelectedInputSource.sourceID(), sessionActive: sessionActive,
            clientIsFront: clientID.map { !$0.isEmpty && $0 == frontID } ?? false))
    }
}
