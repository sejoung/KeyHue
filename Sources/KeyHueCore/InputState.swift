import Foundation

/// 화면에 표시할 최종 입력 상태.
public enum InputState: String, Sendable, Equatable, CaseIterable {
    case korean
    case english
    case capsLock
    case unknown

    /// Caps Lock이 켜져 있으면 Input Source와 무관하게 `.capsLock`이 우선한다.
    public static func resolve(sourceKind: InputSourceKind?, isCapsLockOn: Bool) -> InputState {
        if isCapsLockOn {
            return .capsLock
        }
        switch sourceKind {
        case .korean: return .korean
        case .english: return .english
        case .other, nil: return .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .korean: return "Korean"
        case .english: return "English"
        case .capsLock: return "Caps Lock"
        case .unknown: return "Unknown"
        }
    }

    /// 전환 순간 HUD에 표시할 글리프.
    public var hudGlyph: String {
        switch self {
        case .korean: return "가"
        case .english: return "a"
        case .capsLock: return "A"
        case .unknown: return "?"
        }
    }
}

/// Input Source 자체의 언어 분류. Caps Lock과 무관하다.
public enum InputSourceKind: String, Sendable, Equatable {
    case korean
    case english
    case other
}

/// macOS Input Source에서 읽어 온 값 중 판정에 필요한 것만 담는다.
public struct InputSourceInfo: Sendable, Equatable {
    public var id: String
    public var localizedName: String
    public var languages: [String]
    public var isASCIICapable: Bool

    public init(id: String, localizedName: String, languages: [String], isASCIICapable: Bool) {
        self.id = id
        self.localizedName = localizedName
        self.languages = languages
        self.isASCIICapable = isASCIICapable
    }

    public var kind: InputSourceKind {
        InputSourceClassifier.classify(self)
    }
}

public enum InputSourceClassifier {
    /// 판정 순서
    /// 1. 주 언어가 `ko` → Korean
    /// 2. ASCII 입력이 가능하거나 주 언어가 `en` → English
    /// 3. 그 외(일본어/중국어 IME 등) → Other
    public static func classify(_ info: InputSourceInfo) -> InputSourceKind {
        let primary = info.languages.first?.lowercased() ?? ""
        if primary == "ko" || primary.hasPrefix("ko-") {
            return .korean
        }
        if info.isASCIICapable || primary == "en" || primary.hasPrefix("en-") {
            return .english
        }
        return .other
    }
}
