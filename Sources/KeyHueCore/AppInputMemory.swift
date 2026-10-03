import Foundation

/// Bundle Identifier → 마지막 Input Source ID. (Phase 2: 앱별 Input Source 기억)
/// 입력 내용은 저장하지 않고 Source ID 문자열만 저장한다.
@MainActor
public final class AppInputMemory {
    static let key = "appInputSources"
    /// 가장 오래 안 쓴 앱부터의 순서. 다시 실행해도 그 앱부터 지우려고 따로 저장한다(사전에는 순서가 없다).
    static let orderKey = "appInputSourcesOrder"
    public static let maxEntries = 200

    private let defaults: UserDefaults
    public private(set) var entries: [String: String]
    private var order: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 값 하나가 깨져 있어도 나머지 기억은 살린다.
        let entries = (defaults.dictionary(forKey: Self.key) ?? [:]).compactMapValues { $0 as? String }
        self.entries = entries
        let saved = (defaults.stringArray(forKey: Self.orderKey) ?? []).filter { entries[$0] != nil }
        // 순서를 저장하기 전 버전의 기억은 이름순으로 앞에 둔다(어느 것이 오래됐는지 알 수 없다).
        let savedSet = Set(saved)
        self.order = entries.keys.filter { !savedSet.contains($0) }.sorted() + saved
    }

    /// 앱을 떠날 때마다 불린다. 입력 소스가 그대로여도 그 앱을 가장 최근으로 옮긴다(LRU). 같은 입력 소스로
    /// 자주 쓰는 앱이 먼저 지워지지 않게 한다. 바뀐 것만 저장한다: 이미 가장 최근이고 값도 같으면 쓰지 않는다.
    public func record(sourceID: String, for bundleID: String) {
        let changed = entries[bundleID] != sourceID
        let moved = order.last != bundleID
        guard changed || moved else { return }
        entries[bundleID] = sourceID
        if moved {
            order.removeAll { $0 == bundleID }
            order.append(bundleID)
        }
        var evicted = false
        while order.count > Self.maxEntries {
            entries[order.removeFirst()] = nil
            evicted = true
        }
        if changed || evicted { defaults.set(entries, forKey: Self.key) }
        if moved { defaults.set(order, forKey: Self.orderKey) }
    }

    public func clear() {
        entries = [:]
        order = []
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.orderKey)
    }
}
