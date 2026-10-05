import Foundation
import KeyHueCore

/// Core의 AutoResetCoordinator가 쓰는 실제 입력 소스 전환기(TIS).
@MainActor
final class SystemInputSourceSwitcher: InputSourceSwitching {
    var currentSource: InputSourceInfo? { InputSourceController.current() }
    var availableSources: [InputSourceInfo] { InputSourceController.enabledSources() }
    /// (selected, previous) source IDs after KeyHue's own successful selection.
    var onSelected: ((String, String?) -> Void)?

    @discardableResult
    func perform(_ action: InputSourceAction) -> Bool {
        let previous = InputSourceController.current()?.id
        let ok = InputSourceController.perform(action)
        if ok, let selected = InputSourceController.current()?.id { onSelected?(selected, previous) }
        return ok
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
