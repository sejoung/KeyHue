import Foundation

/// 창 → 마지막 Input Source ID (ADR 0028).
///
/// 창 식별자는 앱이 정한다(AX 창 요소). 앱을 다시 실행하면 창을 다시 알아볼 수 없으므로 **저장하지 않고**
/// 메모리에만 둔다. 창 제목은 쓰지 않는다. 닫힌 창의 기록은 오래된 것부터 버린다.
public struct WindowInputMemory<Window: Hashable> {
    public static var capacity: Int { 100 }

    /// 앱은 그 앱의 창 기록만 지우는 데 쓴다(ADR 0089).
    private struct Entry: Equatable {
        var sourceID: String
        var app: String?
    }

    private var storage = RecentlyUsedMap<Window, Entry>(capacity: Self.capacity)

    public init() {}

    public var count: Int { storage.values.count }

    public func source(for window: Window) -> String? {
        storage.values[window]?.sourceID
    }

    public mutating func record(sourceID: String, for window: Window, app: String? = nil) {
        storage.set(Entry(sourceID: sourceID, app: app), for: window)
    }

    /// 이 앱의 창 기록을 모두 지운다.
    public mutating func forget(app: String) {
        storage.removeAll { $0.app == app }
    }

    public mutating func clear() {
        storage.removeAll()
    }
}
