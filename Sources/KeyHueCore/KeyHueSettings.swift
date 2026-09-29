import Foundation

/// State Bar를 어느 모니터에 표시할지.
public enum DisplayPolicy: String, Sendable, Equatable, CaseIterable {
    case allScreens
    case activeScreen
}

public struct KeyHueSettings: Sendable, Equatable {
    public static let barHeightRange: ClosedRange<Double> = 1...12
    public static let barHeightChoices: [Double] = [1, 2, 3, 4, 6, 8]

    // MVP
    public var showStateBar = true
    public var resetOnAppSwitch = false
    public var resetOnEscape = false
    public var barHeight: Double = 3
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

    public static func clampedBarHeight(_ value: Double) -> Double {
        min(max(value.rounded(), barHeightRange.lowerBound), barHeightRange.upperBound)
    }
}
