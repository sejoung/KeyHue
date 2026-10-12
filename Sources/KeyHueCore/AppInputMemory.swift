import Foundation

/// 앱별 마지막 입력 소스를 기억하는 쪽. 자동 전환(`AutoResetCoordinator`)은 이것에만 의존한다.
/// 앱에서는 UserDefaults에 저장하는 `AppInputMemory`, 테스트에서는 그것이나 가짜 구현을 쓴다.
@MainActor
public protocol AppInputRemembering: AnyObject {
    /// Bundle Identifier → 마지막 Input Source ID
    var entries: [String: String] { get }
    func record(sourceID: String, for bundleID: String)
    func clear()
}

/// Bundle Identifier → 마지막 Input Source ID. (Phase 2: 앱별 Input Source 기억)
/// 입력 내용은 저장하지 않고 Source ID 문자열만 저장한다.
@MainActor
public final class AppInputMemory: AppInputRemembering {
    static let key = "appInputSources"
    /// 가장 오래 안 쓴 앱부터의 순서. 다시 실행해도 그 앱부터 지우려고 따로 저장한다(사전에는 순서가 없다).
    static let orderKey = "appInputSourcesOrder"
    public static let maxEntries = 200

    private let defaults: UserDefaults
    private var storage: RecentlyUsedMap<String, String>
    public var entries: [String: String] { storage.values }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 값 하나가 깨져 있어도 나머지 기억은 살린다.
        let entries = (defaults.dictionary(forKey: Self.key) ?? [:]).compactMapValues { $0 as? String }
        let saved = (defaults.stringArray(forKey: Self.orderKey) ?? []).filter { entries[$0] != nil }
        // 순서를 저장하기 전 버전의 기억은 이름순으로 앞에 둔다(어느 것이 오래됐는지 알 수 없다).
        let savedSet = Set(saved)
        let order = entries.keys.filter { !savedSet.contains($0) }.sorted() + saved
        storage = RecentlyUsedMap(capacity: Self.maxEntries, values: entries, order: order)
    }

    /// 앱을 떠날 때마다 불린다. 입력 소스가 그대로여도 그 앱을 가장 최근으로 옮긴다(LRU). 같은 입력 소스로
    /// 자주 쓰는 앱이 먼저 지워지지 않게 한다. 바뀐 것만 저장한다: 이미 가장 최근이고 값도 같으면 쓰지 않는다.
    public func record(sourceID: String, for bundleID: String) {
        let change = storage.set(sourceID, for: bundleID)
        if change.valueChanged || change.evicted { defaults.set(storage.values, forKey: Self.key) }
        if change.moved { defaults.set(storage.order, forKey: Self.orderKey) }
    }

    public func clear() {
        storage.removeAll()
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.orderKey)
    }
}
