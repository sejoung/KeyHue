import Foundation

/// 로그에 남길 설정 설명(ADR 0036). 문제를 볼 때 "그때 어떤 옵션이 켜져 있었나"를 알 수 있게 한다.
/// 설정에는 입력 내용이나 창 제목 같은 개인 정보가 없다(색, 옵션, 입력 소스 ID뿐).
extension KeyHueSettings {
    /// 기본값과 다른 설정만 `이름=값`으로. 모두 기본값이면 빈 배열.
    public var nonDefaultDescriptions: [String] {
        Self.differences(from: KeyHueSettings(), to: self).map { "\($0.name)=\($0.new)" }
    }

    /// 바뀐 설정만 `이름: 이전 → 새 값`으로.
    public static func changeDescriptions(from old: KeyHueSettings, to new: KeyHueSettings) -> [String] {
        differences(from: old, to: new).map { "\($0.name): \($0.old) → \($0.new)" }
    }

    private static func differences(from old: KeyHueSettings, to new: KeyHueSettings) -> [(name: String, old: String, new: String)] {
        let oldValues = Mirror(reflecting: old).children
        let newValues = Mirror(reflecting: new).children
        return zip(oldValues, newValues).compactMap { oldChild, newChild in
            guard let name = newChild.label else { return nil }
            let before = logDescription(oldChild.value)
            let after = logDescription(newChild.value)
            return before == after ? nil : (name, before, after)
        }
    }

    /// 색은 hex로, Optional은 벗겨서(없으면 "-"), 사전은 키 순서대로.
    static func logDescription(_ value: Any) -> String {
        if let color = value as? RGBAColor {
            return color.hexString
        }
        if let colors = value as? [String: RGBAColor] {
            let items = colors.keys.sorted().map { "\($0):\(colors[$0]!.hexString)" }
            return "{\(items.joined(separator: ","))}"
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { logDescription($0.value) } ?? "-"
        }
        return String(describing: value)
    }
}

// MARK: - 자동 전환 로그

extension InputSourceAction: CustomStringConvertible {
    /// 로그용 짧은 이름: `none`, `default(auto)`, `default(com.apple.keylayout.ABC)`, `select(com.apple.keylayout.ABC)`
    public var description: String {
        switch self {
        case .none: return "none"
        case .selectDefault(let preferredID): return "default(\(preferredID ?? "auto"))"
        case .select(let sourceID): return "select(\(sourceID))"
        }
    }
}

extension AutoResetCoordinator.Event: CustomStringConvertible {
    public var description: String {
        switch self {
        case .skipped(let action): return "skipped \(action) (already there)"
        case .keptManualSwitch: return "kept manual switch made while the app switch settled"
        case .switched(let action, let ok): return "switched \(action) \(ok ? "ok" : "FAILED")"
        case .retrying(let action): return "retrying \(action) (overwritten)"
        }
    }
}
