import Carbon
import Foundation
import KeyHueCore

/// 선택된 Input Source 변경을 macOS distributed notification으로 구독한다.
/// 키 입력으로 추측하지 않고 항상 TIS에서 실제 선택된 Source를 다시 읽는다.
@MainActor
final class InputSourceMonitor {
    private var observers: [NSObjectProtocol] = []
    private var onChange: ((InputSourceInfo?) -> Void)?

    func start(onChange: @escaping (InputSourceInfo?) -> Void) {
        self.onChange = onChange
        let center = DistributedNotificationCenter.default()
        let names: [CFString?] = [
            kTISNotifySelectedKeyboardInputSourceChanged,
            kTISNotifyEnabledKeyboardInputSourcesChanged
        ]
        observers = names.compactMap { $0 as String? }.map { name in
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        onChange?(InputSourceController.current())
    }

    func stop() {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers = []
    }
}
