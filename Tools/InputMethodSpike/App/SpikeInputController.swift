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

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? any IMKTextInput else { return false }
        // 실제 콜백 문맥은 T단계에서 관찰한다. 순서를 바꾸는 비동기 디스패치는 사용하지 않는다.
        guard Thread.isMainThread else {
            SpikeLog.error("key callback outside main thread; event passed through session=\(sessionID)")
            return false
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
        if !flags.intersection([.command, .control, .option]).isEmpty {
            apply(session.finish(), to: client)
            return false
        }
        if event.keyCode == 51 {
            let result = session.backspace()
            apply(result.actions, to: client)
            return result.handled
        }
        let key = MistypeKeyMap.key(keyCode: Int64(event.keyCode), shift: flags.contains(.shift), otherModifiers: false)
        if case .letter(let letter) = key {
            // Caps Lock은 영문 실험에만 반영한다. 한글 쌍자음은 Shift로만 만든다.
            let value = session.mode == .latin && flags.contains(.capsLock)
                ? Character(flags.contains(.shift) ? letter.lowercased() : letter.uppercased()) : letter
            let result = session.letter(value)
            apply(result.actions, to: client)
            return result.handled
        }
        // 경계·기호·Return·Tab·커서 키는 확정 뒤 앱이 한 번 처리한다.
        apply(session.finish(), to: client)
        return false
    }

    override func commitComposition(_ sender: Any!) {
        guard Thread.isMainThread, let client = sender as? any IMKTextInput else { return }
        apply(session.finish(), to: client)
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
