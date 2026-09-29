import Foundation

/// State Bar를 어느 모니터에 표시할지.
public enum DisplayPolicy: String, Sendable, Equatable, CaseIterable {
    case allScreens
    case activeScreen
}

/// State Bar가 붙는 화면 가장자리.
public enum BarPosition: String, Sendable, Equatable, CaseIterable {
    case top
    case bottom
    case left
    case right

    public var isHorizontal: Bool { self == .top || self == .bottom }
}

/// UI 언어. `system`은 OS 언어 설정을 따른다(ADR 0016).
public enum AppLanguage: String, Sendable, Equatable, CaseIterable {
    case system
    case en
    case ko
    case ja

    /// 언어 선택 목록에 쓰는 자기 언어 이름(autonym). 번역하지 않는다.
    public var nativeName: String? {
        switch self {
        case .system: return nil
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }

    /// 번역 리소스 폴더 이름(`<code>.lproj`). system은 nil.
    public var lprojName: String? {
        self == .system ? nil : rawValue
    }
}

public struct KeyHueSettings: Sendable, Equatable {
    public static let barHeightRange: ClosedRange<Double> = 1...16
    public static let barHeightChoices: [Double] = [1, 2, 3, 4, 6, 8, 10, 12, 16]
    public static let barOpacityRange: ClosedRange<Double> = 0.2...1
    public static let barOpacityChoices: [Double] = [1, 0.8, 0.6, 0.4]

    // 일반
    public var appLanguage = AppLanguage.system
    /// Dock 아이콘 표시. 끄면 메뉴바에만 있는 앱(accessory)이 된다. ADR 0020.
    public var showDockIcon = true

    // State Bar
    public var showStateBar = true
    /// 막대 두께(pt). 세로 배치(left/right)에서는 폭으로 쓴다.
    public var barHeight: Double = 3
    /// 상단은 눈에 잘 띄지만 메뉴바를 가려서 기본은 하단으로 둔다. ADR 0012.
    public var barPosition = BarPosition.bottom
    /// State Bar에만 적용한다(HUD, 메뉴바 아이콘 제외). 상태색 자체의 alpha와 곱해진다.
    public var barOpacity: Double = 1

    // 색상 (ADR 0013)
    /// 사용자가 직접 지정한 입력 소스별 색(Input Source ID → 색). 없으면 `SourcePalette` 기본색.
    public var sourceColors: [String: RGBAColor] = [:]
    public var capsLockColor = RGBAColor.defaultCapsLock
    public var unknownColor = RGBAColor.defaultUnknown
    /// 메뉴바 카멜레온을 현재 상태색으로 칠한다. false면 시스템 template(흑백).
    public var tintMenuBarIcon = true

    // 자동 전환
    public var resetOnAppSwitch = false
    public var resetOnEscape = false
    /// 자동 전환의 목표. nil이면 자동(ABC → U.S. → 첫 영문 배열).
    public var defaultSourceID: String?

    // Phase 2 (모두 opt-in)
    public var displayPolicy = DisplayPolicy.allScreens
    public var showHUD = false
    public var rememberInputPerApp = false
    public var resetOnTextFocusLoss = false
    /// 같은 앱 안에서 다른 창(탭)으로 옮기면 기본 입력 소스로 전환. 손쉬운 사용 권한 필요(ADR 0027).
    public var resetOnWindowSwitch = false

    public init() {}

    public func color(for source: InputSourceInfo) -> RGBAColor {
        sourceColors[source.id] ?? SourcePalette.defaultColor(for: source)
    }

    public func color(for state: InputState) -> RGBAColor {
        switch state {
        case .source(let info): return color(for: info)
        case .capsLock: return capsLockColor
        case .unknown: return unknownColor
        }
    }

    /// State Bar에 실제로 칠할 색(상태색 × 막대 opacity).
    public func barColor(for state: InputState) -> RGBAColor {
        var color = color(for: state)
        color.alpha *= barOpacity
        return color
    }

    /// 기본색과 같은 색을 지정하면 override를 지운다(기본 팔레트가 바뀌면 따라가도록).
    public mutating func setColor(_ color: RGBAColor, for source: InputSourceInfo) {
        sourceColors[source.id] = color == SourcePalette.defaultColor(for: source) ? nil : color
    }

    public mutating func resetColor(for source: InputSourceInfo) {
        sourceColors[source.id] = nil
    }

    public mutating func resetColors() {
        let defaults = KeyHueSettings()
        sourceColors = defaults.sourceColors
        capsLockColor = defaults.capsLockColor
        unknownColor = defaults.unknownColor
    }

    public static func clampedBarHeight(_ value: Double) -> Double {
        guard value.isFinite else { return KeyHueSettings().barHeight }
        return min(max(value.rounded(), barHeightRange.lowerBound), barHeightRange.upperBound)
    }

    public static func clampedBarOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return barOpacityRange.upperBound }
        return min(max(value, barOpacityRange.lowerBound), barOpacityRange.upperBound)
    }
}
