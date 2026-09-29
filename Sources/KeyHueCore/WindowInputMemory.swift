import Foundation

/// 창 → 마지막 Input Source ID (ADR 0028).
///
/// 창 식별자는 앱이 정한다(AX 창 요소). 앱을 다시 실행하면 창을 다시 알아볼 수 없으므로 **저장하지 않고**
/// 메모리에만 둔다. 창 제목은 쓰지 않는다. 닫힌 창의 기록은 오래된 것부터 버린다.
public struct WindowInputMemory<Window: Hashable> {
    public static var capacity: Int { 100 }

    private var entries: [Window: String] = [:]
    private var order: [Window] = []

    public init() {}

    public var count: Int { entries.count }

    public func source(for window: Window) -> String? {
        entries[window]
    }

    public mutating func record(sourceID: String, for window: Window) {
        entries[window] = sourceID
        order.removeAll { $0 == window }
        order.append(window)
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    public mutating func clear() {
        entries = [:]
        order = []
    }
}
