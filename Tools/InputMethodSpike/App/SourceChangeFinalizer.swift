import AppKit
import InputMethodKit
import KeyHueInputMethodSpikeCore

/// The session a source-change commit belongs to.
protocol SourceChangeHost: AnyObject {
    var isActive: Bool { get }
    /// Changes with every callback that can change what the client shows.
    var contextGeneration: Int { get }
    var sessionMode: ProbeSession.Mode { get }
    var pendingText: String? { get }
    /// The client of this session now.
    var currentClient: (any IMKTextInput)? { get }
    /// Commits the verified composition. Empty when nothing was committed.
    func finishAfterSourceChange(inputSourceID: String, verifiedMarkedText: String?) -> [ProbeSession.Action]
}

/// Another source selected without a callback to this session reaches it only as
/// the TIS notification. The composition is committed into the exact mark the
/// client still shows, and only after every state read around the client's
/// replies is the same again (a reply can reenter this session).
final class SourceChangeFinalizer {
    private weak var host: (any SourceChangeHost)?
    private let sessionID: String
    private var finishing = false

    init(host: any SourceChangeHost, sessionID: String) {
        self.host = host
        self.sessionID = sessionID
    }

    func sourceDidChange() {
        guard let host, host.isActive, !finishing,
              let pendingText = host.pendingText,
              let selectedID = SelectedInputSource.sourceID(),
              ProbeSession.Mode(inputSourceID: selectedID) != host.sessionMode,
              let client = host.currentClient else { return }
        finishing = true
        defer { finishing = false }
        let generation = host.contextGeneration
        let foregroundMatches = { FrontClient.isFront(client.bundleIdentifier()) }
        guard foregroundMatches() else { return }
        let markedRange = client.markedRange()
        let selection = client.selectedRange()
        SpikeLog.notice("composition source notification session=\(sessionID) target=\(selectedID) markedKnown=\(markedRange.location != NSNotFound) markedLength=\(markedRange.length) selectionLength=\(selection.length)")
        guard SourceChangeCommit.marksComposition(pendingText, markedRange: markedRange, selection: selection) else { return }
        let markedText = client.attributedSubstring(from: markedRange)?.string
        let confirmedRange = client.markedRange()
        let confirmedSelection = client.selectedRange()
        guard host.isActive,
              host.currentClient as AnyObject? === client as AnyObject,
              markedText == pendingText,
              confirmedRange == markedRange, confirmedSelection == selection, foregroundMatches(),
              SelectedInputSource.sourceID() == selectedID,
              host.contextGeneration == generation, host.pendingText == pendingText else { return }
        let actions = host.finishAfterSourceChange(inputSourceID: selectedID, verifiedMarkedText: markedText)
        guard !actions.isEmpty else { return }
        // Use the verified mark, not a potentially moved current selection.
        for case .commit(let text) in actions { client.insertText(text, replacementRange: markedRange) }
        SpikeLog.notice("composition finalized after source notification session=\(sessionID) target=\(selectedID)")
    }
}
