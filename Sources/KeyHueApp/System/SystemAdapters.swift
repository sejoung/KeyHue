import Foundation
import KeyHueCore

/// Core의 AutoResetCoordinator가 쓰는 실제 입력 소스 전환기(TIS).
@MainActor
final class SystemInputSourceSwitcher: InputSourceSwitching {
    var currentSource: InputSourceInfo? { InputSourceController.current() }

    @discardableResult
    func perform(_ action: InputSourceAction) -> Bool {
        InputSourceController.perform(action)
    }
}

/// Core의 AutoResetCoordinator가 쓰는 1회성 지연 실행(main queue).
@MainActor
final class MainQueueScheduler: Scheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }
}
