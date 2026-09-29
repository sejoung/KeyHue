import Foundation

/// 모니터들이 보고한 원시 값(Input Source, Caps Lock)을 하나의 상태로 통합한다.
public struct InputSnapshot: Sendable, Equatable {
    public var source: InputSourceInfo?
    public var isCapsLockOn: Bool

    public init(source: InputSourceInfo? = nil, isCapsLockOn: Bool = false) {
        self.source = source
        self.isCapsLockOn = isCapsLockOn
    }

    public var state: InputState {
        InputState.resolve(sourceKind: source?.kind, isCapsLockOn: isCapsLockOn)
    }
}

/// Monitors → InputStateStore → (Overlay, StatusBar, HUD, AutoReset)
/// UI는 OS 이벤트를 직접 받지 않고 이 store만 구독한다.
@MainActor
public final class InputStateStore {
    public private(set) var snapshot = InputSnapshot()
    private var observers: [(InputSnapshot, InputSnapshot) -> Void] = []

    public init() {}

    public var state: InputState { snapshot.state }

    public func updateSource(_ source: InputSourceInfo?) {
        apply { $0.source = source }
    }

    public func updateCapsLock(_ isOn: Bool) {
        apply { $0.isCapsLockOn = isOn }
    }

    /// 값이 실제로 바뀐 경우에만 observer를 호출한다(중복 notification 흡수).
    public func addObserver(_ observer: @escaping (_ old: InputSnapshot, _ new: InputSnapshot) -> Void) {
        observers.append(observer)
    }

    private func apply(_ change: (inout InputSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        guard next != snapshot else { return }
        let previous = snapshot
        snapshot = next
        observers.forEach { $0(previous, next) }
    }
}
