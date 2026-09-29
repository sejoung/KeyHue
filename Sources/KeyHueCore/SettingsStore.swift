import Foundation

/// `KeyHueSettings`를 UserDefaults에 저장/복원한다. DB나 파일을 쓰지 않는다.
@MainActor
public final class SettingsStore {
    enum Key {
        static let showStateBar = "showStateBar"
        static let resetOnAppSwitch = "resetOnAppSwitch"
        static let resetOnEscape = "resetOnEscape"
        static let barHeight = "barHeight"
        static let koreanColor = "koreanColor"
        static let englishColor = "englishColor"
        static let capsLockColor = "capsLockColor"
        static let unknownColor = "unknownColor"
        static let displayPolicy = "displayPolicy"
        static let showHUD = "showHUD"
        static let rememberInputPerApp = "rememberInputPerApp"
        static let resetOnTextFocusLoss = "resetOnTextFocusLoss"
    }

    private let defaults: UserDefaults
    private var observers: [(KeyHueSettings, KeyHueSettings) -> Void] = []

    public private(set) var settings: KeyHueSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    /// 변경 후 값이 달라졌을 때만 저장하고 observer에 (old, new)를 전달한다.
    public func update(_ change: (inout KeyHueSettings) -> Void) {
        var next = settings
        change(&next)
        next.barHeight = KeyHueSettings.clampedBarHeight(next.barHeight)
        guard next != settings else { return }
        let previous = settings
        settings = next
        save(next)
        observers.forEach { $0(previous, next) }
    }

    public func addObserver(_ observer: @escaping (_ old: KeyHueSettings, _ new: KeyHueSettings) -> Void) {
        observers.append(observer)
    }

    private static func load(from defaults: UserDefaults) -> KeyHueSettings {
        var s = KeyHueSettings()
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func color(_ key: String, _ fallback: RGBAColor) -> RGBAColor {
            defaults.string(forKey: key).flatMap(RGBAColor.init(hex:)) ?? fallback
        }
        s.showStateBar = bool(Key.showStateBar, s.showStateBar)
        s.resetOnAppSwitch = bool(Key.resetOnAppSwitch, s.resetOnAppSwitch)
        s.resetOnEscape = bool(Key.resetOnEscape, s.resetOnEscape)
        if defaults.object(forKey: Key.barHeight) != nil {
            s.barHeight = KeyHueSettings.clampedBarHeight(defaults.double(forKey: Key.barHeight))
        }
        s.koreanColor = color(Key.koreanColor, s.koreanColor)
        s.englishColor = color(Key.englishColor, s.englishColor)
        s.capsLockColor = color(Key.capsLockColor, s.capsLockColor)
        s.unknownColor = color(Key.unknownColor, s.unknownColor)
        s.displayPolicy = defaults.string(forKey: Key.displayPolicy).flatMap(DisplayPolicy.init(rawValue:)) ?? s.displayPolicy
        s.showHUD = bool(Key.showHUD, s.showHUD)
        s.rememberInputPerApp = bool(Key.rememberInputPerApp, s.rememberInputPerApp)
        s.resetOnTextFocusLoss = bool(Key.resetOnTextFocusLoss, s.resetOnTextFocusLoss)
        return s
    }

    private func save(_ s: KeyHueSettings) {
        defaults.set(s.showStateBar, forKey: Key.showStateBar)
        defaults.set(s.resetOnAppSwitch, forKey: Key.resetOnAppSwitch)
        defaults.set(s.resetOnEscape, forKey: Key.resetOnEscape)
        defaults.set(s.barHeight, forKey: Key.barHeight)
        defaults.set(s.koreanColor.hexString, forKey: Key.koreanColor)
        defaults.set(s.englishColor.hexString, forKey: Key.englishColor)
        defaults.set(s.capsLockColor.hexString, forKey: Key.capsLockColor)
        defaults.set(s.unknownColor.hexString, forKey: Key.unknownColor)
        defaults.set(s.displayPolicy.rawValue, forKey: Key.displayPolicy)
        defaults.set(s.showHUD, forKey: Key.showHUD)
        defaults.set(s.rememberInputPerApp, forKey: Key.rememberInputPerApp)
        defaults.set(s.resetOnTextFocusLoss, forKey: Key.resetOnTextFocusLoss)
    }
}
