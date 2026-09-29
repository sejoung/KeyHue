import AppKit

/// Caps Lock 상태를 `flagsChanged` 이벤트로 감지한다. Timer polling은 하지 않는다.
///
/// Global monitor는 다른 앱이 앞에 있을 때, local monitor는 KeyHue 메뉴가 열려 있을 때를 담당한다.
/// 이벤트를 놓칠 수 있는 구간(권한/세션 전환 등)은 `refresh()`를 앱 전환·Source 변경·깨어남 시점에
/// 호출해 HID 상태에서 다시 읽는 방식으로 보정한다.
@MainActor
final class CapsLockMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onChange: ((Bool) -> Void)?

    static var isCapsLockOn: Bool {
        CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isOn = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.onChange?(isOn) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isOn = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.onChange?(isOn) }
            return event
        }
        refresh()
    }

    func refresh() {
        onChange?(Self.isCapsLockOn)
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
    }
}
