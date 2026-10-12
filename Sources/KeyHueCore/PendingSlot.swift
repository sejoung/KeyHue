import Foundation

/// 한 번에 하나만 기다리는 예약 작업(앱·창 전환 대기, 전환 뒤 확인)의 세대 번호.
///
/// 새로 시작하면 이전 예약은 낡은 것이 되고, 취소하면 기다리는 것이 없다. 예약한 작업은 실행될 때
/// `finish`로 아직 자기 차례인지 확인한다(아니면 아무것도 하지 않는다).
struct PendingSlot<Value> {
    private var generation = 0
    private var pending: (value: Value, generation: Int)?

    /// 기다리는 예약이 있다.
    var isPending: Bool { pending != nil }
    /// 기다리는 예약의 값.
    var value: Value? { pending?.value }

    /// 새 예약을 시작하고 그 세대 번호를 돌려준다. 이전 예약은 더 이상 `finish`되지 않는다.
    mutating func start(_ value: Value) -> Int {
        generation += 1
        pending = (value, generation)
        return generation
    }

    /// 이 세대의 예약이 아직 기다리는 중이면 끝내고 true. 새 예약에 밀렸거나 취소됐으면 false.
    mutating func finish(_ token: Int) -> Bool {
        guard pending?.generation == token else { return false }
        pending = nil
        return true
    }

    mutating func cancel() {
        pending = nil
    }
}

extension PendingSlot where Value == Void {
    mutating func start() -> Int {
        start(())
    }
}
