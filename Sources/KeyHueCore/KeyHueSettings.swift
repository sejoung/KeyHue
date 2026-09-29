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

public struct KeyHueSettings: Sendable, Equatable {
    public static let barHeightRange: ClosedRange<Double> = 1...16
    public static let barHeightChoices: [Double] = [1, 2, 3, 4, 6, 8, 10, 12, 16]
    public static let barOpacityRange: ClosedRange<Double> = 0.2...1
    public static let barOpacityChoices: [Double] = [1, 0.8, 0.6, 0.4]

    // MVP
    public var showStateBar = true
    public var resetOnAppSwitch = false
    public var resetOnEscape = false
    /// 막대 두께(pt). 세로 배치(left/right)에서는 폭으로 쓴다.
    public var barHeight: Double = 3
    /// 상단은 눈에 잘 띄지만 메뉴바를 가려서 기본은 하단으로 둔다. ADR 0012.
    public var barPosition = BarPosition.bottom
    /// State Bar에만 적용한다(HUD, 메뉴바 아이콘 제외). 상태색 자체의 alpha와 곱해진다.
    public var barOpacity: Double = 1
    public var koreanColor = RGBAColor.defaultKorean
    public var englishColor = RGBAColor.defaultEnglish
    public var capsLockColor = RGBAColor.defaultCapsLock
    public var unknownColor = RGBAColor.defaultUnknown
    /// 메뉴바 카멜레온을 현재 상태색으로 칠한다. false면 시스템 template(흑백).
    public var tintMenuBarIcon = true

    // Phase 2 (모두 opt-in)
    public var displayPolicy = DisplayPolicy.allScreens
    public var showHUD = false
    public var rememberInputPerApp = false
    public var resetOnTextFocusLoss = false

    public init() {}

    public func color(for state: InputState) -> RGBAColor {
        switch state {
        case .korean: return koreanColor
        case .english: return englishColor
        case .capsLock: return capsLockColor
        case .unknown: return unknownColor
        }
    }

    public mutating func setColor(_ color: RGBAColor, for state: InputState) {
        switch state {
        case .korean: koreanColor = color
        case .english: englishColor = color
        case .capsLock: capsLockColor = color
        case .unknown: unknownColor = color
        }
    }

    public mutating func resetColors() {
        let defaults = KeyHueSettings()
        koreanColor = defaults.koreanColor
        englishColor = defaults.englishColor
        capsLockColor = defaults.capsLockColor
        unknownColor = defaults.unknownColor
    }

    /// State Bar에 실제로 칠할 색(상태색 × 막대 opacity).
    public func barColor(for state: InputState) -> RGBAColor {
        var color = color(for: state)
        color.alpha *= barOpacity
        return color
    }

    public static func clampedBarHeight(_ value: Double) -> Double {
        min(max(value.rounded(), barHeightRange.lowerBound), barHeightRange.upperBound)
    }

    public static func clampedBarOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return barOpacityRange.upperBound }
        return min(max(value, barOpacityRange.lowerBound), barOpacityRange.upperBound)
    }
}
