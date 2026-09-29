import Foundation

/// Bundle Identifier → 마지막 Input Source ID. (Phase 2: 앱별 Input Source 기억)
/// 입력 내용은 저장하지 않고 Source ID 문자열만 저장한다.
@MainActor
public final class AppInputMemory {
    static let key = "appInputSources"
    public static let maxEntries = 200

    private let defaults: UserDefaults
    public private(set) var entries: [String: String]
    private var order: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        self.order = Array(entries.keys)
    }

    public func record(sourceID: String, for bundleID: String) {
        guard entries[bundleID] != sourceID else { return }
        entries[bundleID] = sourceID
        order.removeAll { $0 == bundleID }
        order.append(bundleID)
        while order.count > Self.maxEntries {
            entries[order.removeFirst()] = nil
        }
        defaults.set(entries, forKey: Self.key)
    }

    public func clear() {
        entries = [:]
        order = []
        defaults.removeObject(forKey: Self.key)
    }
}
