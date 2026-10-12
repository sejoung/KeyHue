import AppKit
import Carbon
import InputMethodKit
import KeyHueInputMethodSpikeCore

@objc(KeyHueSpikeInputController)
final class SpikeInputController: IMKInputController {
    private var session = ProbeSession()
    private let sessionID = UUID().uuidString
    private lazy var corrections = SpikeCorrectionCoordinator(sessionID: sessionID, sessionComposing: { [weak self] in
        // Unknown once the controller is gone: keep the conservative reading.
        self.map { $0.session.pendingText != nil } ?? true
    })
    private lazy var sourceChange = SourceChangeFinalizer(host: self, sessionID: sessionID)
    /// ADR 0066: a composition committed after the key that ended it.
    private lazy var detachedCommits = DetachedCommitDelivery(apply: { [weak self] actions, client in
        self?.apply(actions, to: client)
    })
    private(set) var isActive = false
    private var loggedEditorInput = false
    private var keyAcknowledgement = KeyAcknowledgement() // a key confirms the session to the utility
    private var observesSelection = false
    private(set) var contextGeneration = 0

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
        sourceChange.sourceDidChange()
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
        detachedCommits.deliver()
        observeSelection()
        isActive = true
        loggedEditorInput = false; keyAcknowledgement.reset()
        corrections.invalidate(.activation)
        corrections.activated(client: sender as? any IMKTextInput)
        if let client = sender as? any IMKTextInput,
           let actions = session.synchronize(inputSourceID: SelectedInputSource.modeID()) {
            apply(actions, to: client)
            afterPendingDeactivation {
                SessionAcknowledgementPoster.post(SessionAcknowledgement.forModeCallback(
                    requestedID: $0.session.mode.inputSourceID,
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
        let correction = corrections.mode(for: client)
        corrections.eventArrives(client: client, mode: correction)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            detachedCommits.deliver()
            corrections.click(mode: correction)
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
        if corrections.passesPostedKey(event, modifiers: otherModifiers, mode: correction) { return false }
        let detached = DetachedCommit.applies(clientID: client.bundleIdentifier(), keyCode: event.keyCode,
                                              otherModifiers: otherModifiers)
        // A key faster than the held commit's delivery (ADR 0066).
        if detachedCommits.beforeKey(detached: detached, client: client) { return true }
        guard synchronizeBeforeKey(client) else { return false }
        let steps = corrections.steps(for: event, mode: correction)
        if steps.shortcut == .requestFix {
            // ADR 0068: the user asks for a fix. The composition is committed first
            // so it is part of the word; the key never reaches the app.
            detachedCommits.commitForShortcut(clientID: client.bundleIdentifier(), committed: session.finish(), client: client)
            corrections.requestFix(client: client, mode: session.mode, isCurrent: isCurrent(client))
            return true
        }
        let route = InputRouting.route(keyCode: event.keyCode, shift: flags.contains(.shift), capsLock: flags.contains(.capsLock),
                                       otherModifiers: otherModifiers, mode: session.mode)
        if corrections.key(route, event: event, otherModifiers: otherModifiers, steps: steps, composing: session.pendingText != nil,
                           client: client, mode: session.mode, isCurrent: isCurrent(client)) {
            return true
        }
        if DetachedCommit.holdsCommit(detached: detached, route: route, composing: session.pendingText != nil) {
            // The client would send the text with this key and drop it. Consume the
            // key and commit once the key has finished there (ADR 0066).
            detachedCommits.hold(session.finish(), client: client)
            return true
        }
        let result = session.handle(route)
        apply(result.actions, to: client)
        corrections.keyHandled(client: client, mode: correction, isCurrent: isCurrent(client))
        return result.handled
    }

    /// Matches the session to the client and the selected mode before a key.
    /// false: no KeyHue mode is selected; the composition is finished and the key passes.
    private func synchronizeBeforeKey(_ client: any IMKTextInput) -> Bool {
        // 앱이 조합을 이미 확정했거나 버렸으면 우리 쪽 조합도 비운다(같은 글자를 다시 넣지 않는다).
        let clientMarkedRange = client.markedRange()
        if session.reconcile(clientHasMarkedText: clientMarkedRange.length > 0) {
            corrections.invalidate(.clientReconciliation)
            SpikeLog.notice("composition finished by client; dropped session=\(sessionID)")
        }
        // TISSelectInputSource can switch between this server's modes without
        // delivering another activation/setValue callback to this controller.
        // Read the actual mode before *every* key, including Backspace/boundaries.
        let previousMode = session.mode
        guard let actions = session.synchronize(inputSourceID: SelectedInputSource.modeID()) else {
            corrections.invalidate()
            apply(session.finish(), to: client)
            return false
        }
        apply(actions, to: client)
        if let id = keyAcknowledgement.key(in: session.mode) { SessionAcknowledgementPoster.post(id) }
        if previousMode != session.mode {
            SpikeLog.notice("mode synchronized session=\(sessionID) from=\(previousMode.rawValue) to=\(session.mode.rawValue)")
        }
        return true
    }

    override func commitComposition(_ sender: Any!) {
        guard Thread.isMainThread else {
            // 다른 스레드에서 클라이언트를 건드리지 않는다. 남은 조합은 다음 키에서 앱 상태와 맞춘다.
            SpikeLog.error("commit request outside main thread; composition kept session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        detachedCommits.deliver()
        guard let client = sender as? any IMKTextInput else { return }
        corrections.invalidate(.commitCallback)
        apply(session.finish(), to: client)
    }

    /// 앱이 조합 취소를 요청해도 버리지 않고 확정한다(마지막 글자를 잃지 않는다).
    override func cancelComposition() {
        guard Thread.isMainThread else {
            SpikeLog.error("cancel request outside main thread; composition kept session=\(sessionID)")
            return
        }
        contextGeneration &+= 1
        detachedCommits.deliver()
        guard let client = client() else { return }
        corrections.invalidate(.cancelCallback)
        apply(session.cancelComposition(), to: client)
    }

    override func deactivateServer(_ sender: Any!) {
        if Thread.isMainThread {
            contextGeneration &+= 1
            isActive = false
            corrections.invalidateContext()
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
        detachedCommits.deliver()
        corrections.modeRequested(ProbeSession.Mode(inputSourceID: id)!, client: client)
        // A delayed callback must not override a newer TIS selection. Activation
        // can also precede TIS publication; the key-time check above reconciles it.
        let oldMode = session.mode
        guard let actions = session.synchronize(inputSourceID: SelectedInputSource.modeID()) else { return }
        if oldMode != session.mode {
            corrections.invalidate(.modeCallback)
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
        // A client can deactivate this server inside one of these edits; the
        // deactivation commits the composition, so its pending mark is stale (ADR 0086).
        let ended = session.endedCompositions
        let skipped = SpikeClientText.apply(actions, to: client, compositionEnded: { session.endedCompositions != ended },
                                            observeMarked: { session.observeClientMarkedText($0) })
        if skipped > 0 {
            SpikeLog.notice("composition ended during delivery; stale mark skipped session=\(sessionID) client=\(SpikeClientText.clientName(client))")
        }
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

extension SpikeInputController: SourceChangeHost {
    var sessionMode: ProbeSession.Mode { session.mode }
    var pendingText: String? { session.pendingText }
    var currentClient: (any IMKTextInput)? { client() }

    func finishAfterSourceChange(inputSourceID: String, verifiedMarkedText: String?) -> [ProbeSession.Action] {
        let actions = session.finishAfterSourceChange(inputSourceID: inputSourceID, verifiedMarkedText: verifiedMarkedText)
        if !actions.isEmpty {
            contextGeneration &+= 1
            corrections.invalidateContext()
        }
        return actions
    }
}
