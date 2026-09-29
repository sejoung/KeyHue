import Carbon
import Foundation
import KeyHueCore

/// 선택된 Input Source 변경을 macOS distributed notification으로 구독한다.
/// 키 입력으로 추측하지 않고 항상 TIS에서 실제 선택된 Source를 다시 읽는다.
///
/// **suspensionBehavior는 `.deliverImmediately`여야 한다(ADR 0023).** 기본값(블록 API 포함)은
/// 앱이 비활성일 때 알림을 모아 두었다가 늦게 전달해서, 실측에서 전환의 약 1/4이 0.7–1.5초 늦게 반영됐다.
/// KeyHue는 거의 항상 비활성 상태로 동작하므로 즉시 전달이 필요하다.
@MainActor
final class InputSourceMonitor: NSObject {
    private var onChange: ((InputSourceInfo?) -> Void)?
    private var isObserving = false

    static let notificationNames: [Notification.Name] = [
        kTISNotifySelectedKeyboardInputSourceChanged,
        kTISNotifyEnabledKeyboardInputSourcesChanged
    ].compactMap { $0 as String? }.map { Notification.Name($0) }

    func start(onChange: @escaping (InputSourceInfo?) -> Void) {
        self.onChange = onChange
        if !isObserving {
            let center = DistributedNotificationCenter.default()
            for name in Self.notificationNames {
                center.addObserver(
                    self,
                    selector: #selector(inputSourceDidChange(_:)),
                    name: name,
                    object: nil,
                    suspensionBehavior: .deliverImmediately
                )
            }
            isObserving = true
        }
        refresh()
    }

    @objc private func inputSourceDidChange(_ notification: Notification) {
        // 등록한 스레드(main)의 run loop에서 전달된다.
        MainActor.assumeIsolated { refresh() }
    }

    func refresh() {
        onChange?(InputSourceController.current())
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        isObserving = false
    }
}
