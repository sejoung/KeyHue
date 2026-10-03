import AppKit
import Carbon
import InputMethodKit
import KeyHueCore
import KeyHueInputMethodSpikeCore

@objc(KeyHueSpikeInputController)
final class SpikeInputController: IMKInputController {
    private var session = ProbeSession()
    private let sessionID = UUID().uuidString

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        guard Thread.isMainThread else {
            SpikeLog.error("activation outside main thread session=\(sessionID)")
            return
        }
        if let client = sender as? any IMKTextInput,
           let actions = session.synchronize(inputSourceID: currentSelectedModeID()) {
            apply(actions, to: client)
            SpikeLog.notice("activate session=\(sessionID) mode=\(session.mode.rawValue)")
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
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // 클릭은 앱이 처리한다. 커서가 옮겨지기 전에 조합 중인 글자를 확정한다.
            apply(session.handle(InputRouting.routeMouseDown()).actions, to: client)
            return false
        case .keyDown:
            break
        default:
            return false
        }
        // 앱이 조합을 이미 확정했거나 버렸으면 우리 쪽 조합도 비운다(같은 글자를 다시 넣지 않는다).
        if session.reconcile(clientHasMarkedText: client.markedRange().length > 0) {
            SpikeLog.notice("composition finished by client; dropped session=\(sessionID)")
        }
        // TISSelectInputSource can switch between this server's modes without
        // delivering another activation/setValue callback to this controller.
        // Read the actual mode before *every* key, including Backspace/boundaries.
        let previousMode = session.mode
        guard let actions = session.synchronize(inputSourceID: currentSelectedModeID()) else {
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
        let result = session.handle(route)
        apply(result.actions, to: client)
        return result.handled
    }

    override func commitComposition(_ sender: Any!) {
        guard Thread.isMainThread else {
            // 다른 스레드에서 클라이언트를 건드리지 않는다. 남은 조합은 다음 키에서 앱 상태와 맞춘다.
            SpikeLog.error("commit request outside main thread; composition kept session=\(sessionID)")
            return
        }
        guard let client = sender as? any IMKTextInput else { return }
        apply(session.finish(), to: client)
    }

    /// 앱이 조합 취소를 요청해도 버리지 않고 확정한다(마지막 글자를 잃지 않는다).
    override func cancelComposition() {
        guard Thread.isMainThread else {
            SpikeLog.error("cancel request outside main thread; composition kept session=\(sessionID)")
            return
        }
        guard let client = client() else { return }
        apply(session.cancelComposition(), to: client)
    }

    override func deactivateServer(_ sender: Any!) {
        SpikeLog.notice("deactivate session=\(sessionID) mode=\(session.mode.rawValue)")
        commitComposition(sender)
        super.deactivateServer(sender)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard Thread.isMainThread, tag == Int(kTextServiceInputModePropertyTag),
              let id = value as? String, ProbeSession.Mode(inputSourceID: id) != nil,
              let client = sender as? any IMKTextInput else { return }
        // A delayed callback must not override a newer TIS selection. Activation
        // can also precede TIS publication; the key-time check above reconciles it.
        guard let actions = session.synchronize(inputSourceID: currentSelectedModeID()) else { return }
        apply(actions, to: client)
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
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private func currentSelectedModeID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func string(_ key: CFString) -> String? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        // The selected source ID is authoritative when present. Do not reinterpret
        // another input source using a stale mode property from this server.
        if let id = string(kTISPropertyInputSourceID) {
            if ProbeSession.Mode(inputSourceID: id) != nil { return id }
            guard id == SpikeMetadata.bundleID else { return nil }
        }
        guard let id = string(kTISPropertyInputModeID), ProbeSession.Mode(inputSourceID: id) != nil else { return nil }
        return id
    }
}
