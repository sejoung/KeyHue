import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

@objc(KeyHueSpikeInputController)
final class SpikeInputController: IMKInputController {
    private var session = ProbeSession()
    private let sessionID = UUID().uuidString
    private var correctionProbe: IMKCorrectionProbe?
    private var probeEventCount = 0
    private var isActive = false
    private var loggedEditorInput = false
    private var observesSelection = false
    private var finishingSourceChange = false
    private var contextGeneration = 0

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    private func observeSelection() {
        guard !observesSelection else { return }
        DistributedNotificationCenter.default().addObserver(self,
            selector: #selector(selectedSourceDidChange(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
        observesSelection = true
    }

    @objc private func selectedSourceDidChange(_ notification: Notification) {
        guard Thread.isMainThread else { return }
        acknowledgeSelectionChange()
        guard isActive, !finishingSourceChange,
              let pendingText = session.pendingText,
              let selectedID = currentSelectedSourceID(),
              ProbeSession.Mode(inputSourceID: selectedID) != session.mode,
              let client = client() else { return }
        finishingSourceChange = true
        defer { finishingSourceChange = false }
        let generation = contextGeneration
        let foregroundMatches = {
            guard let frontID = MainActor.assumeIsolated({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }),
                  let clientID = client.bundleIdentifier(), !clientID.isEmpty else { return false }
            return frontID == clientID
        }
        guard foregroundMatches() else { return }
        let markedRange = client.markedRange()
        let selection = client.selectedRange()
        SpikeLog.notice("composition source notification session=\(sessionID) target=\(selectedID) markedKnown=\(markedRange.location != NSNotFound) markedLength=\(markedRange.length) selectionLength=\(selection.length)")
        guard markedRange.location != NSNotFound, markedRange.location >= 0,
              markedRange.length > 0,
              markedRange.length == pendingText.utf16.count,
              markedRange.location <= Int.max - markedRange.length,
              CorrectionProbe.typingCaret(selection: selection, markedRange: markedRange) == NSMaxRange(markedRange) else { return }
        let markedText = client.attributedSubstring(from: markedRange)?.string
        let confirmedRange = client.markedRange()
        let confirmedSelection = client.selectedRange()
        guard isActive,
              self.client() as AnyObject? === client as AnyObject,
              markedText == pendingText,
              confirmedRange == markedRange, confirmedSelection == selection, foregroundMatches(),
              currentSelectedSourceID() == selectedID,
              contextGeneration == generation, session.pendingText == pendingText else { return }
        let actions = session.finishAfterSourceChange(inputSourceID: selectedID, verifiedMarkedText: markedText)
        guard !actions.isEmpty else { return }
        contextGeneration &+= 1
        withProbe { $0.invalidateContext() }
        // Use the verified mark, not a potentially moved current selection.
        for case .commit(let text) in actions { client.insertText(text, replacementRange: markedRange) }
        SpikeLog.notice("composition finalized after source notification session=\(sessionID) target=\(selectedID)")
    }

    // All callers already reject non-main-thread IMK callbacks. Keep this
    // synchronous rather than moving text edits across concurrency domains.
    private func withProbe<T>(_ body: (IMKCorrectionProbe) -> T) -> T {
        if correctionProbe == nil { correctionProbe = IMKCorrectionProbe() }
        return body(correctionProbe!)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        guard Thread.isMainThread else {
            SpikeLog.error("activation outside main thread session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        observeSelection()
        isActive = true
        loggedEditorInput = false
        withProbe { $0.invalidate(reason: "activation") }
        if let client = sender as? any IMKTextInput,
           let actions = session.synchronize(inputSourceID: currentSelectedModeID()) {
            apply(actions, to: client)
            acknowledge(SessionAcknowledgement.forModeCallback(requestedID: session.mode == .hangul ? SpikeMetadata.hangulID : SpikeMetadata.latinID))
            SpikeLog.notice("activate session=\(sessionID) mode=\(session.mode.rawValue) client=\(Self.clientName(client))")
        } else {
            SpikeLog.error("activation rejected session=\(sessionID) selected=\(currentSelectedModeID() ?? "foreign-or-missing") clientValid=\(sender is any IMKTextInput)")
        }
    }

    /// 키 입력에 더해 클릭도 받는다. 클릭이 커서를 옮기기 전에 조합을 확정하려는 것이다.
    override func recognizedEvents(_ sender: Any!) -> Int {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        return super.recognizedEvents(sender) | Int(mouse.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? any IMKTextInput else { return false }
        // 실제 콜백 문맥은 T단계에서 관찰한다. 순서를 바꾸는 비동기 디스패치는 사용하지 않는다.
        guard Thread.isMainThread else {
            SpikeLog.error("event callback outside main thread; event passed through session=\(sessionID)")
            return false
        }
        contextGeneration &+= 1
        if !loggedEditorInput {
            loggedEditorInput = true
            SpikeLog.notice("editor input reached server session=\(sessionID) client=\(Self.clientName(client)) selected=\(currentSelectedModeID() ?? "foreign-or-missing")")
        }
        if client.bundleIdentifier() == IMKCorrectionProbe.clientBundleID {
            withProbe { $0.interrupt(client: client, identity: sessionID, currentMode: {
                self.currentSelectedModeID().flatMap(ProbeSession.Mode.init(inputSourceID:))
            }) }
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            withProbe { $0.invalidate(reason: "mouse") }
            // 클릭은 앱이 처리한다. 커서가 옮겨지기 전에 조합 중인 글자를 확정한다.
            apply(session.handle(InputRouting.routeMouseDown()).actions, to: client)
            return false
        case .keyDown:
            break
        default:
            return false
        }
        // 앱이 조합을 이미 확정했거나 버렸으면 우리 쪽 조합도 비운다(같은 글자를 다시 넣지 않는다).
        let clientMarkedRange = client.markedRange()
        if session.reconcile(clientHasMarkedText: clientMarkedRange.length > 0) {
            withProbe { $0.invalidate(reason: "client reconciliation") }
            SpikeLog.notice("composition finished by client; dropped session=\(sessionID)")
        }
        // TISSelectInputSource can switch between this server's modes without
        // delivering another activation/setValue callback to this controller.
        // Read the actual mode before *every* key, including Backspace/boundaries.
        let previousMode = session.mode
        guard let actions = session.synchronize(inputSourceID: currentSelectedModeID()) else {
            withProbe { $0.invalidate() }
            apply(session.finish(), to: client)
            return false
        }
        apply(actions, to: client)
        if previousMode != session.mode {
            SpikeLog.notice("mode synchronized session=\(sessionID) from=\(previousMode.rawValue) to=\(session.mode.rawValue)")
        }
        let flags = event.modifierFlags
        let route = InputRouting.route(keyCode: event.keyCode, shift: flags.contains(.shift), capsLock: flags.contains(.capsLock),
                                       otherModifiers: !flags.intersection([.command, .control, .option]).isEmpty, mode: session.mode)
        // This experiment is reachable only from the dedicated host-test bundle.
        // Ordinary input uses exactly the existing composition path below.
        if client.bundleIdentifier() == IMKCorrectionProbe.clientBundleID {
            probeEventCount += 1
            let kind: String
            switch event.keyCode {
            case 49: kind = "space"
            case 51: kind = "backspace"
            default: if case .compose = route { kind = "letter" } else { kind = "other" }
            }
            SpikeLog.notice("correction probe event session=\(sessionID) ordinal=\(probeEventCount) kind=\(kind) mode=\(session.mode.rawValue) selectionLength=\(client.selectedRange().length) markedLength=\(client.markedRange().length)")
            let modifiers = !flags.intersection([.command, .control, .option, .shift]).isEmpty
            let selectedMode = { self.currentSelectedModeID().flatMap(ProbeSession.Mode.init(inputSourceID:)) }
            if event.keyCode == 49, !modifiers {
                _ = withProbe { $0.space(client: client, identity: sessionID, currentMode: selectedMode) }
            } else if event.keyCode == 51, !modifiers {
                if withProbe({ $0.backspace(client: client, identity: sessionID, currentMode: selectedMode) }) {
                    scheduleCorrection(client: client)
                    return true
                }
            } else if case .compose(let key) = route {
                withProbe { $0.letter(key, client: client, mode: session.mode) }
            } else {
                withProbe { $0.invalidate() }
            }
        }
        let result = session.handle(route)
        apply(result.actions, to: client)
        if client.bundleIdentifier() == IMKCorrectionProbe.clientBundleID { scheduleCorrection(client: client) }
        return result.handled
    }

    private func scheduleCorrection(client: any IMKTextInput) {
        withProbe { $0.schedule(client: client, identity: sessionID, currentMode: { [weak self] in
            self?.currentSelectedModeID().flatMap(ProbeSession.Mode.init(inputSourceID:))
        }, isCurrent: { [weak self] in
            guard let self, self.isActive, let currentClient = self.client(),
                  currentClient as AnyObject === client as AnyObject,
                  self.currentSelectedModeID() != nil else { return false }
            return MainActor.assumeIsolated {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == IMKCorrectionProbe.clientBundleID
            }
        }) }
    }

    override func commitComposition(_ sender: Any!) {
        guard Thread.isMainThread else {
            // 다른 스레드에서 클라이언트를 건드리지 않는다. 남은 조합은 다음 키에서 앱 상태와 맞춘다.
            SpikeLog.error("commit request outside main thread; composition kept session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        guard let client = sender as? any IMKTextInput else { return }
        withProbe { $0.invalidate(reason: "commit callback") }
        apply(session.finish(), to: client)
    }

    /// 앱이 조합 취소를 요청해도 버리지 않고 확정한다(마지막 글자를 잃지 않는다).
    override func cancelComposition() {
        guard Thread.isMainThread else {
            SpikeLog.error("cancel request outside main thread; composition kept session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        guard let client = client() else { return }
        withProbe { $0.invalidate(reason: "cancel callback") }
        apply(session.cancelComposition(), to: client)
    }

    override func deactivateServer(_ sender: Any!) {
        if Thread.isMainThread {
            contextGeneration &+= 1
            isActive = false
            withProbe { $0.invalidateContext() }
        }
        SpikeLog.notice("deactivate session=\(sessionID) mode=\(session.mode.rawValue) client=\(Self.clientName(sender as? any IMKTextInput))")
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard Thread.isMainThread, tag == Int(kTextServiceInputModePropertyTag),
              let id = value as? String, ProbeSession.Mode(inputSourceID: id) != nil,
              let client = sender as? any IMKTextInput else { return }
        contextGeneration &+= 1
        withProbe { $0.modeRequested(ProbeSession.Mode(inputSourceID: id)!) }
        // A delayed callback must not override a newer TIS selection. Activation
        // can also precede TIS publication; the key-time check above reconciles it.
        let oldMode = session.mode
        guard let actions = session.synchronize(inputSourceID: currentSelectedModeID()) else { return }
        if oldMode != session.mode {
            withProbe { $0.invalidate(reason: "mode callback") }
        }
        apply(actions, to: client)
        acknowledge(SessionAcknowledgement.forModeCallback(requestedID: id))
        // 입력 내용은 로그에 넘기지 않는다. 모드와 실행 문맥만 관찰한다.
        SpikeLog.notice("mode callback session=\(sessionID) requested=\(id) observed=\(session.mode.rawValue) mainThread=\(Thread.isMainThread)")
    }

    private func apply(_ actions: [ProbeSession.Action], to client: any IMKTextInput) {
        for action in actions {
            switch action {
            case .mark(let text):
                client.setMarkedText(text, selectionRange: NSRange(location: text.utf16.count, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                // 이 앱이 조합 범위를 알려 주는지 기록한다. 알려 주는 앱에서만 앱 상태와 맞춘다.
                session.observeClientMarkedText(!text.isEmpty && client.markedRange().length > 0)
            case .commit(let text):
                // IMKTextInput specifies NSNotFound for both components when
                // inserting at the current selection/inline composition.
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            }
        }
    }

    /// Tells the utility that a client session reached this server (ADR 0062). Only
    /// the mode ID is sent: no client, document or key information.
    private func acknowledge(_ modeID: String?) {
        guard let modeID else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(InputMethodIntegration.sessionAcknowledgement), object: modeID,
            userInfo: nil, deliverImmediately: true)
    }

    /// An existing session in the front client receives a selection between this
    /// server's modes without a callback; answer it so the utility does not repair.
    private func acknowledgeSelectionChange() {
        let clientID = isActive ? client()?.bundleIdentifier() : nil
        let frontID = MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        acknowledge(SessionAcknowledgement.forSelectionChange(
            selectedID: currentSelectedSourceID(), sessionActive: isActive,
            clientIsFront: clientID.map { !$0.isEmpty && $0 == frontID } ?? false))
    }

    /// Only the client's bundle ID enters the log, never its document state.
    private static func clientName(_ client: (any IMKTextInput)?) -> String {
        guard let id = client?.bundleIdentifier(), !id.isEmpty else { return "unknown" }
        return id
    }

    private func currentSelectedModeID() -> String? {
        guard let id = currentSelectedSourceID(), ProbeSession.Mode(inputSourceID: id) != nil else { return nil }
        return id
    }

    private func currentSelectedSourceID() -> String? {
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
