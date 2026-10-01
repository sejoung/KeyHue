import AppKit

/// 전역 keyDown을 listen-only CGEventTap으로 관찰한다(ADR 0008, 0041).
///
/// - 이벤트를 수정/차단하지 않는다(listen-only).
/// - **키 코드와 수정 키 상태만** 읽는다. 이벤트의 문자열(unicode string)은 읽지 않는다.
///   - ESC 전환: 키 코드가 ESC인지만 본다.
///   - 잘못된 언어 경고(실험적, 켰을 때만): 키 위치로 단어를 모아 판정한 뒤 바로 버린다(메모리에만, 기록·로그 없음).
///     커서가 움직였을 수 있음을 알기 위해 마우스 클릭도 관찰한다(위치는 읽지 않는다).
/// - Input Monitoring 권한이 필요하므로 옵션을 켰을 때만 시작한다.
@MainActor
final class KeyboardMonitor {
    struct KeyDown {
        let keyCode: Int64
        let isAutoRepeat: Bool
        let shift: Bool
        /// ⌘·⌃·⌥ 중 하나라도 눌렀다(단축키).
        let otherModifiers: Bool
        let capsLock: Bool
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var observesMouse = false

    var onKeyDown: ((KeyDown) -> Void)?
    var onMouseDown: (() -> Void)?

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// 시스템 권한 요청 대화상자를 띄우고 System Settings > Input Monitoring 목록에 KeyHue를 추가한다.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    /// 권한이 없거나 tap 생성에 실패하면 false. 호출자는 기능을 비활성 상태로 표시한다.
    /// - observeMouse: 마우스 클릭도 받는다(잘못된 언어 경고에서만). 바뀌면 tap을 다시 만든다.
    @discardableResult
    func start(observeMouse: Bool = false) -> Bool {
        if tap != nil, observesMouse != observeMouse { stop() }
        // 실행 중에 권한을 거둬 가면 tap은 남아 있어도 이벤트가 오지 않는다. "동작 중"으로 보이지 않게 멈춘다.
        if tap != nil, !Self.hasPermission {
            Log.keyboard.notice("Input Monitoring was revoked; keyboard monitor stopped")
            stop()
        }
        guard tap == nil else { return true }
        guard Self.hasPermission else {
            Log.keyboard.notice("Input Monitoring not granted; keyboard monitor not started")
            return false
        }

        var mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if observeMouse {
            mask |= CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: refcon
        ) else {
            Log.keyboard.error("CGEvent.tapCreate failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        self.observesMouse = observeMouse
        Log.keyboard.notice("keyboard monitor started (mouse: \(observeMouse))")
        return true
    }

    func stop() {
        if tap != nil {
            Log.keyboard.notice("keyboard monitor stopped")
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, key: KeyDown?) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.keyboard.notice("event tap disabled by system (\(type.rawValue)); re-enabling")
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .keyDown:
            guard let key else { return }
            // ESC 외의 키는 기록하지 않는다.
            if key.keyCode == 53 {
                Log.keyboard.debug("ESC keyDown (autorepeat: \(key.isAutoRepeat))")
            }
            onKeyDown?(key)
        case .leftMouseDown, .rightMouseDown:
            onMouseDown?()
        default:
            break
        }
    }
}

private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        // 키 코드·autorepeat·수정 키만 꺼낸다. 문자(unicode string)는 읽지 않는다.
        var key: KeyboardMonitor.KeyDown?
        if type == .keyDown {
            let flags = event.flags
            key = KeyboardMonitor.KeyDown(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                shift: flags.contains(.maskShift),
                otherModifiers: !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]),
                capsLock: flags.contains(.maskAlphaShift)
            )
        }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
        // tap의 run loop source는 main run loop에 등록되어 있다.
        MainActor.assumeIsolated {
            monitor.handle(type: type, key: key)
        }
    }
    return Unmanaged.passUnretained(event)
}
