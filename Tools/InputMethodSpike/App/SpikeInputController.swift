import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

@objc(KeyHueSpikeInputController)
final class SpikeInputController: IMKInputController {
    private var session = ProbeSession()
    private let sessionID = UUID().uuidString
    /// ADR 0064: automatic fixes, only in clients routed to `.automatic`.
    private lazy var automatic = SpikeAutomaticCorrection(sessionID: sessionID, sessionComposing: { [weak self] in
        // Unknown once the controller is gone: keep the conservative reading.
        self.map { $0.session.pendingText != nil } ?? true
    })
    /// ADR 0068: fixes the user asks for with the shortcut, in every routed client.
    private lazy var shortcutCorrection = IMKShortcutCorrection()
    private var lastCorrectionMode: CorrectionMode?
    private var isActive = false
    private var loggedEditorInput = false
    private var keyAcknowledgement = KeyAcknowledgement() // a key confirms the session to the utility
    private var observesSelection = false
    private var finishingSourceChange = false
    private var contextGeneration = 0
    /// ADR 0066: a composition committed after the key that ended it, for clients
    /// that drop text committed with Tab or a navigation key.
    private var heldCommit = HeldCommit()
    private var heldCommitClient: (any IMKTextInput)?

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    private func observeSelection() {
        guard !observesSelection else { return }
        DistributedNotificationCenter.default().addObserver(self,
            selector: #selector(selectedSourceDidChange),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
        observesSelection = true
    }

    @objc private func selectedSourceDidChange() {
        guard Thread.isMainThread else { return }
        // A closing session may still look active here; ask again once its
        // deactivation has arrived (`SessionAcknowledgement.confirmationDelay`).
        afterPendingDeactivation { $0.acknowledgeSelectionChange() }
        guard isActive, !finishingSourceChange,
              let pendingText = session.pendingText,
              let selectedID = SelectedInputSource.sourceID(),
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
              SelectedInputSource.sourceID() == selectedID,
              contextGeneration == generation, session.pendingText == pendingText else { return }
        let actions = session.finishAfterSourceChange(inputSourceID: selectedID, verifiedMarkedText: markedText)
        guard !actions.isEmpty else { return }
        contextGeneration &+= 1
        automatic.probe.invalidateContext()
        // Use the verified mark, not a potentially moved current selection.
        for case .commit(let text) in actions { client.insertText(text, replacementRange: markedRange) }
        SpikeLog.notice("composition finalized after source notification session=\(sessionID) target=\(selectedID)")
    }

    /// The correction route of this client (ADR 0064). nil: never enters the
    /// correction path. A changed route (setting changed) drops both adapters' state.
    private func correctionMode(_ client: (any IMKTextInput)?) -> CorrectionMode? {
        let mode = SpikeCorrectionSettings.shared.mode(for: client?.bundleIdentifier())
        if mode != lastCorrectionMode {
            lastCorrectionMode = mode
            shortcutCorrection.interrupt(reason: "settings")
            automatic.probe.invalidateContext()
        }
        return mode
    }

    /// Whether `client` is still this active session's client when a delayed step runs.
    private func isCurrent(_ client: any IMKTextInput) -> () -> Bool {
        { [weak self] in
            guard let self, self.isActive, let current = self.client() else { return false }
            return current as AnyObject === client as AnyObject
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        guard Thread.isMainThread else {
            SpikeLog.error("activation outside main thread session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        deliverHeldCommit()
        observeSelection()
        isActive = true
        loggedEditorInput = false; keyAcknowledgement.reset()
        automatic.probe.invalidate(reason: "activation")
        SpikeCorrectionSettings.shared.start()
        switch correctionMode(sender as? any IMKTextInput) {
        case .automatic: automatic.probe.activated(); shortcutCorrection.activated()
        case .manual: shortcutCorrection.activated()
        case .off, nil: break
        }
        if let client = sender as? any IMKTextInput,
           let actions = session.synchronize(inputSourceID: SelectedInputSource.modeID()) {
            apply(actions, to: client)
            afterPendingDeactivation {
                SessionAcknowledgementPoster.post(SessionAcknowledgement.forModeCallback(
                    requestedID: $0.session.mode == .hangul ? SpikeMetadata.hangulID : SpikeMetadata.latinID,
                    sessionActive: $0.isActive))
            }
            SpikeLog.notice("activate session=\(sessionID) mode=\(session.mode.rawValue) client=\(SpikeClientText.clientName(client))")
        } else {
            SpikeLog.error("activation rejected session=\(sessionID) selected=\(SelectedInputSource.modeID() ?? "foreign-or-missing") clientValid=\(sender is any IMKTextInput)")
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
            SpikeLog.notice("editor input reached server session=\(sessionID) client=\(SpikeClientText.clientName(client)) selected=\(SelectedInputSource.modeID() ?? "foreign-or-missing")")
        }
        let correction = correctionMode(client)
        if correction == .automatic {
            automatic.interrupt(client: client)
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            deliverHeldCommit()
            automatic.probe.invalidate(reason: "mouse")
            if correction != nil { shortcutCorrection.interrupt(reason: "click") }
            // 클릭은 앱이 처리한다. 커서가 옮겨지기 전에 조합 중인 글자를 확정한다.
            apply(session.handle(InputRouting.routeMouseDown()).actions, to: client)
            return false
        case .keyDown:
            break
        default:
            return false
        }
        let flags = event.modifierFlags
        let otherModifiers = !flags.intersection([.command, .control, .option]).isEmpty
        // Terminal fixing's own Backspaces pass to the client untouched (ADR 0067).
        if correction != nil, shortcutCorrection.postedKeyArrived(event, modifiers: otherModifiers) { return false }
        let detached = DetachedCommit.applies(clientID: client.bundleIdentifier(), keyCode: event.keyCode,
                                              otherModifiers: otherModifiers)
        // A key faster than the held commit's delivery (ADR 0066).
        let held = heldCommit.beforeKey(detached: detached)
        if held.consumeKey { return true }
        if !held.deliver.isEmpty {
            apply(held.deliver, to: heldCommitClient ?? client)
            heldCommitClient = nil
        }
        // 앱이 조합을 이미 확정했거나 버렸으면 우리 쪽 조합도 비운다(같은 글자를 다시 넣지 않는다).
        let clientMarkedRange = client.markedRange()
        if session.reconcile(clientHasMarkedText: clientMarkedRange.length > 0) {
            automatic.probe.invalidate(reason: "client reconciliation")
            SpikeLog.notice("composition finished by client; dropped session=\(sessionID)")
        }
        // TISSelectInputSource can switch between this server's modes without
        // delivering another activation/setValue callback to this controller.
        // Read the actual mode before *every* key, including Backspace/boundaries.
        let previousMode = session.mode
        guard let actions = session.synchronize(inputSourceID: SelectedInputSource.modeID()) else {
            automatic.probe.invalidate()
            apply(session.finish(), to: client)
            return false
        }
        apply(actions, to: client)
        if let id = keyAcknowledgement.key(in: session.mode) { SessionAcknowledgementPoster.post(id) }
        if previousMode != session.mode {
            SpikeLog.notice("mode synchronized session=\(sessionID) from=\(previousMode.rawValue) to=\(session.mode.rawValue)")
        }
        // A password prompt is never fixed and its keys are not remembered.
        let secureInput = correction != nil && IsSecureEventInputEnabled()
        let handlesShortcut = CorrectionRouting.handlesShortcut(mode: correction, secureInput: secureInput)
        if secureInput, shortcutCorrection.isShortcut(event) {
            SpikeLog.notice("shortcut correction skipped reason=secureInput")
        }
        if handlesShortcut, shortcutCorrection.isShortcut(event) {
            // ADR 0068: the user asks for a fix. The composition is committed first
            // so it is part of the word; the key never reaches the app.
            let consumed = DetachedCommit.consume(clientID: client.bundleIdentifier(), committed: session.finish())
            apply(consumed.now, to: client)
            if !consumed.after.isEmpty {
                // Same main-queue work item pattern as the held commit.
                DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                    guard let self, Thread.isMainThread else { return }
                    self.apply(consumed.after, to: client)
                })
            }
            automatic.probe.invalidate(reason: "shortcut")
            shortcutCorrection.request(client: client, mode: session.mode, isCurrent: isCurrent(client))
            return true
        }
        let route = InputRouting.route(keyCode: event.keyCode, shift: flags.contains(.shift), capsLock: flags.contains(.capsLock),
                                       otherModifiers: otherModifiers, mode: session.mode)
        if handlesShortcut {
            shortcutCorrection.key(route, keyCode: event.keyCode, modifiers: otherModifiers, shift: flags.contains(.shift), text: event.characters,
                                   composing: session.pendingText != nil, client: client, mode: session.mode)
        } else if secureInput {
            shortcutCorrection.interrupt(reason: "secure input")
        }
        // Automatic correction for routed clients. Unrouted clients use exactly the
        // existing composition path below.
        if correction == .automatic,
           automatic.key(event, route: route, mode: session.mode, client: client, isCurrent: isCurrent(client)) {
            return true
        }
        if detached, route == .commitAndPass, session.pendingText != nil {
            // The client would send the text with this key and drop it. Consume the
            // key and commit once the key has finished there (ADR 0066).
            heldCommit.hold(session.finish())
            heldCommitClient = client
            // Same main-queue work item pattern as the correction probes.
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                guard let self, Thread.isMainThread else { return }
                self.deliverHeldCommit()
            })
            return true
        }
        let result = session.handle(route)
        apply(result.actions, to: client)
        if correction == .automatic { automatic.schedule(client: client, isCurrent: isCurrent(client)) }
        return result.handled
    }

    /// Delivers the held commit before anything else reaches the client (ADR 0066).
    private func deliverHeldCommit() {
        guard !heldCommit.isEmpty else { return }
        let actions = heldCommit.take()
        if let client = heldCommitClient { apply(actions, to: client) }
        heldCommitClient = nil
    }

    override func commitComposition(_ sender: Any!) {
        guard Thread.isMainThread else {
            // 다른 스레드에서 클라이언트를 건드리지 않는다. 남은 조합은 다음 키에서 앱 상태와 맞춘다.
            SpikeLog.error("commit request outside main thread; composition kept session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        deliverHeldCommit()
        guard let client = sender as? any IMKTextInput else { return }
        automatic.probe.invalidate(reason: "commit callback")
        apply(session.finish(), to: client)
    }

    /// 앱이 조합 취소를 요청해도 버리지 않고 확정한다(마지막 글자를 잃지 않는다).
    override func cancelComposition() {
        guard Thread.isMainThread else {
            SpikeLog.error("cancel request outside main thread; composition kept session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        deliverHeldCommit()
        guard let client = client() else { return }
        automatic.probe.invalidate(reason: "cancel callback")
        apply(session.cancelComposition(), to: client)
    }

    override func deactivateServer(_ sender: Any!) {
        if Thread.isMainThread {
            contextGeneration &+= 1
            isActive = false
            automatic.probe.invalidateContext()
        }
        SpikeLog.notice("deactivate session=\(sessionID) mode=\(session.mode.rawValue) client=\(SpikeClientText.clientName(sender as? any IMKTextInput))")
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard Thread.isMainThread, tag == Int(kTextServiceInputModePropertyTag),
              let id = value as? String, ProbeSession.Mode(inputSourceID: id) != nil,
              let client = sender as? any IMKTextInput else { return }
        contextGeneration &+= 1
        deliverHeldCommit()
        if correctionMode(client) == .automatic {
            automatic.probe.modeRequested(ProbeSession.Mode(inputSourceID: id)!, client: client)
        }
        // A delayed callback must not override a newer TIS selection. Activation
        // can also precede TIS publication; the key-time check above reconciles it.
        let oldMode = session.mode
        guard let actions = session.synchronize(inputSourceID: SelectedInputSource.modeID()) else { return }
        if oldMode != session.mode {
            automatic.probe.invalidate(reason: "mode callback")
        }
        apply(actions, to: client)
        afterPendingDeactivation {
            SessionAcknowledgementPoster.post(SessionAcknowledgement.forModeCallback(requestedID: id, sessionActive: $0.isActive))
        }
        // 입력 내용은 로그에 넘기지 않는다. 모드와 실행 문맥만 관찰한다.
        SpikeLog.notice("mode callback session=\(sessionID) requested=\(id) observed=\(session.mode.rawValue) mainThread=\(Thread.isMainThread)")
    }

    private func apply(_ actions: [ProbeSession.Action], to client: any IMKTextInput) {
        // 이 앱이 조합 범위를 알려 주는지 기록한다. 알려 주는 앱에서만 앱 상태와 맞춘다.
        SpikeClientText.apply(actions, to: client) { session.observeClientMarkedText($0) }
    }

    /// A client can activate a session for another process's selection and close it
    /// in the next millisecond (ADR 0070). Acknowledge only what is still open then.
    private func afterPendingDeactivation(_ body: @escaping (SpikeInputController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionAcknowledgement.confirmationDelay,
                                      execute: DispatchWorkItem { [weak self] in
            guard let self, Thread.isMainThread else { return }
            body(self)
        })
    }

    /// An existing session in the front client receives a selection between this
    /// server's modes without a callback; answer it so the utility does not repair.
    private func acknowledgeSelectionChange() {
        SessionAcknowledgementPoster.postSelectionChange(sessionActive: isActive,
                                                         clientID: isActive ? client()?.bundleIdentifier() : nil)
    }
}
