import Foundation

/// 아직 준비되지 않은 대상에 붙기를 짧은 간격으로 몇 번 다시 시도한다(ADR 0033).
///
/// 앱 활성화 알림은 앱이 실행을 마치기 전에 온다. 그때 AX 알림 등록은 `kAXErrorCannotComplete`로 실패하고,
/// 실측에서 100 ms 뒤에는 성공했다. 실패를 무시하면 다른 앱에 갔다 올 때까지 그 앱의 창 전환을 보지 못한다.
/// - 대상이 바뀌거나 `cancel()`하면 남은 재시도는 버린다.
/// - 간격이 끝나도 실패하면 포기한다. 다음 앱 활성화 때 다시 붙는다.
@MainActor
public final class AttachRetrier<Target: Equatable> {
    /// 실패 뒤 다시 시도하기까지의 간격. 합쳐서 약 3초.
    public static var delays: [TimeInterval] { [0.1, 0.2, 0.4, 0.8, 1.5] }

    private let scheduler: Scheduling
    private var generation = 0

    /// 다시 시도하려고 기다리는 대상. 없으면 nil.
    public private(set) var pendingTarget: Target?

    public init(scheduler: Scheduling) {
        self.scheduler = scheduler
    }

    /// 바로 한 번 시도하고, `attempt`가 false(아직 준비 안 됨)면 간격마다 다시 시도한다.
    /// 끝까지 실패하면 `onGiveUp`을 부른다(로그용). 취소되거나 대상이 바뀐 경우는 부르지 않는다.
    public func start(
        _ target: Target,
        attempt: @escaping @MainActor (Target) -> Bool,
        onGiveUp: @escaping @MainActor (Target) -> Void = { _ in }
    ) {
        cancel()
        run(target, failures: 0, attempt: attempt, onGiveUp: onGiveUp)
    }

    public func cancel() {
        generation += 1
        pendingTarget = nil
    }

    private func run(
        _ target: Target,
        failures: Int,
        attempt: @escaping @MainActor (Target) -> Bool,
        onGiveUp: @escaping @MainActor (Target) -> Void
    ) {
        pendingTarget = nil
        guard !attempt(target) else { return }
        guard failures < Self.delays.count else {
            onGiveUp(target)
            return
        }
        pendingTarget = target
        let current = generation
        scheduler.schedule(after: Self.delays[failures]) { [weak self] in
            guard let self, self.generation == current, self.pendingTarget == target else { return }
            self.run(target, failures: failures + 1, attempt: attempt, onGiveUp: onGiveUp)
        }
    }
}
