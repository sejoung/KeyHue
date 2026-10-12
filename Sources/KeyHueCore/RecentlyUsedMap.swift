import Foundation

/// 키 → 값과, 가장 오래 안 쓴 키부터의 순서. 개수가 `capacity`를 넘으면 오래된 것부터 버린다(LRU).
/// 앱별 기억(`AppInputMemory`)과 창별 기억(`WindowInputMemory`)이 함께 쓴다. 저장은 쓰는 쪽이 맡는다.
struct RecentlyUsedMap<Key: Hashable, Value: Equatable> {
    /// `set`이 바꾼 것. 저장하는 쪽은 바뀐 것만 다시 쓴다.
    struct Change {
        /// 값이 새로 생기거나 달라졌다.
        var valueChanged = false
        /// 키가 가장 최근으로 옮겨졌다(새 키 포함).
        var moved = false
        /// 개수를 넘어 오래된 키를 버렸다.
        var evicted = false
    }

    let capacity: Int
    private(set) var values: [Key: Value]
    /// 가장 오래 안 쓴 키가 앞이다.
    private(set) var order: [Key]

    /// 저장해 둔 값과 순서로 되살린다. 순서는 그대로 믿는다(정리는 쓰는 쪽이 한다).
    init(capacity: Int, values: [Key: Value] = [:], order: [Key] = []) {
        self.capacity = capacity
        self.values = values
        self.order = order
    }

    /// 값을 기록하고 그 키를 가장 최근으로 옮긴다. 이미 가장 최근이고 값도 같으면 아무것도 바꾸지 않는다.
    @discardableResult
    mutating func set(_ value: Value, for key: Key) -> Change {
        var change = Change(valueChanged: values[key] != value, moved: order.last != key)
        guard change.valueChanged || change.moved else { return change }
        values[key] = value
        if change.moved {
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > capacity {
            values[order.removeFirst()] = nil
            change.evicted = true
        }
        return change
    }

    mutating func removeAll() {
        values = [:]
        order = []
    }

    mutating func removeAll(where shouldRemove: (Value) -> Bool) {
        values = values.filter { !shouldRemove($0.value) }
        order.removeAll { values[$0] == nil }
    }
}
