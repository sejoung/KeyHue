import Foundation

/// macOS Input Source에서 읽어 온 값 중 판정에 필요한 것만 담는다.
public struct InputSourceInfo: Sendable, Hashable {
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

    /// 지역 태그를 뗀 주 언어 코드(`ko-KR` → `ko`). 없으면 빈 문자열.
    public var primaryLanguage: String {
        let tag = languages.first?.lowercased() ?? ""
        return tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    /// 영문 알파벳을 그대로 입력하는 배열(ABC, U.S., German, Dvorak…).
    /// 자동 전환("기본 입력 소스로")의 목표 그룹이자 기본 파란색 그룹이다.
    /// CJK 입력기는 ASCII 모드를 가진 경우가 있어도 이 그룹에 넣지 않는다.
    public var isASCIIBase: Bool {
        guard !Self.nonLatinIMELanguages.contains(primaryLanguage) else { return false }
        return isASCIICapable || primaryLanguage == "en"
    }

    static let nonLatinIMELanguages: Set<String> = ["ko", "ja", "zh", "yue"]
}

/// 화면에 표시할 최종 입력 상태. Caps Lock이 켜져 있으면 Input Source보다 우선한다.
public enum InputState: Sendable, Hashable {
    case source(InputSourceInfo)
    case capsLock
    case unknown

    public static func resolve(source: InputSourceInfo?, isCapsLockOn: Bool) -> InputState {
        if isCapsLockOn {
            return .capsLock
        }
        return source.map(InputState.source) ?? .unknown
    }

    /// 전환 순간 HUD에 표시할 글리프.
    public var hudGlyph: String {
        switch self {
        case .source(let info): return InputSourceGlyph.glyph(for: info)
        case .capsLock: return "A"
        case .unknown: return "?"
        }
    }
}

/// 입력 소스를 한 글자로 나타낸다(HUD용).
public enum InputSourceGlyph {
    static let byLanguage: [String: String] = [
        "ko": "가",
        "ja": "あ",
        "zh": "中", "yue": "中",
        "ru": "Я", "uk": "Я", "be": "Я", "bg": "Я", "sr": "Я", "mk": "Я", "kk": "Я", "ky": "Я", "mn": "Я",
        "el": "α",
        "ar": "ع", "fa": "ع", "ur": "ع",
        "he": "א", "yi": "א",
        "th": "ก",
        "hi": "अ", "mr": "अ", "ne": "अ",
        "hy": "Ա",
        "ka": "ა"
    ]

    public static func glyph(for info: InputSourceInfo) -> String {
        if info.isASCIIBase {
            return "a"
        }
        if info.primaryLanguage == "ja", info.id.localizedCaseInsensitiveContains("katakana") {
            return "ア"
        }
        if let glyph = byLanguage[info.primaryLanguage] {
            return glyph
        }
        return info.localizedName.first.map { String($0) } ?? "?"
    }
}

/// 사용자가 색을 지정하지 않은 입력 소스의 기본 색.
///
/// - 영문 배열(ASCII)은 모두 파랑 하나로 묶는다(가장 흔한 "기본 입력").
/// - 주요 언어는 고정 색을 쓴다(한국어 초록 등). 빨강은 Caps Lock 전용으로 남긴다.
/// - 그 밖의 언어는 언어 코드의 안정적인 해시로 팔레트에서 고른다. 실행할 때마다 같은 색이 나온다.
public enum SourcePalette {
    public static let base = RGBAColor(hex: "#0A84FF")!

    static let green = RGBAColor(hex: "#34C759")!
    static let orange = RGBAColor(hex: "#FF9500")!
    static let purple = RGBAColor(hex: "#BF5AF2")!
    static let teal = RGBAColor(hex: "#30B0C7")!
    static let indigo = RGBAColor(hex: "#5E5CE6")!
    static let mint = RGBAColor(hex: "#00C7BE")!
    static let yellow = RGBAColor(hex: "#FFCC00")!
    static let pink = RGBAColor(hex: "#FF2D55")!
    static let brown = RGBAColor(hex: "#A2845E")!

    static let byLanguage: [String: RGBAColor] = [
        "ko": green,
        "ja": orange,
        "zh": purple, "yue": purple,
        "ru": teal, "uk": teal, "be": teal, "bg": teal, "sr": teal, "mk": teal, "kk": teal,
        "el": indigo,
        "ar": mint, "fa": mint, "ur": mint,
        "he": yellow
    ]

    static let fallback: [RGBAColor] = [mint, indigo, pink, yellow, teal, brown]

    public static func defaultColor(for info: InputSourceInfo) -> RGBAColor {
        if info.isASCIIBase {
            return base
        }
        if let color = byLanguage[info.primaryLanguage] {
            return color
        }
        let key = info.primaryLanguage.isEmpty ? info.id : info.primaryLanguage
        return fallback[Int(stableHash(key) % UInt64(fallback.count))]
    }

    /// FNV-1a. Swift `hashValue`는 실행마다 달라지므로 쓰지 않는다.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
