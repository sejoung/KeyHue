import AppKit

/// 전역 keyDown을 listen-only CGEventTap으로 관찰해 **ESC 여부만** 판단한다.
///
/// - 이벤트를 수정/차단하지 않는다(listen-only).
/// - 키 코드 외의 정보(문자열, 다른 키)는 읽거나 저장하지 않는다.
/// - Input Monitoring 권한이 필요하므로 옵션을 켰을 때만 시작한다.
@MainActor
final class KeyboardMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// (keyCode, isAutoRepeat)
    var onKeyDown: ((Int64, Bool) -> Void)?

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
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else {
            Log.keyboard.notice("Input Monitoring not granted; ESC monitor not started")
            return false
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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
        Log.keyboard.notice("ESC monitor started")
        return true
    }

    func stop() {
        if tap != nil {
            Log.keyboard.notice("ESC monitor stopped")
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

    fileprivate func handle(type: CGEventType, keyCode: Int64, isAutoRepeat: Bool) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.keyboard.notice("event tap disabled by system (\(type.rawValue)); re-enabling")
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .keyDown:
            // ESC 외의 키는 기록하지 않는다.
            if keyCode == 53 {
                Log.keyboard.debug("ESC keyDown (autorepeat: \(isAutoRepeat))")
            }
            onKeyDown?(keyCode, isAutoRepeat)
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
        // 키 코드와 autorepeat 여부만 꺼낸다. 문자(unicode string)는 읽지 않는다.
        let keyCode = type == .keyDown ? event.getIntegerValueField(.keyboardEventKeycode) : -1
        let isAutoRepeat = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
        // tap의 run loop source는 main run loop에 등록되어 있다.
        MainActor.assumeIsolated {
            monitor.handle(type: type, keyCode: keyCode, isAutoRepeat: isAutoRepeat)
        }
    }
    return Unmanaged.passUnretained(event)
}
