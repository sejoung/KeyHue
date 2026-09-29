import Foundation

/// `KeyHueSettings`를 UserDefaults에 저장/복원한다. DB나 파일을 쓰지 않는다.
///
/// **기본값과 다른 값만 저장한다**(ADR 0014). 기본값과 같은 값은 키를 지워서, 이후 버전에서 기본값이
/// 바뀌면 사용자가 건드리지 않은 설정은 새 기본값을 따르게 한다.
@MainActor
public final class SettingsStore {
    enum Key {
        static let appLanguage = "appLanguage"
        static let showDockIcon = "showDockIcon"
        static let showStateBar = "showStateBar"
        static let barHeight = "barHeight"
        static let barPosition = "barPosition"
        static let barOpacity = "barOpacity"
        static let sourceColors = "sourceColors"
        static let capsLockColor = "capsLockColor"
        static let unknownColor = "unknownColor"
        static let tintMenuBarIcon = "tintMenuBarIcon"
        static let onAppSwitch = "onAppSwitch"
        static let resetOnEscape = "resetOnEscape"
        static let defaultSourceID = "defaultSourceID"
        static let displayPolicy = "displayPolicy"
        static let showHUD = "showHUD"
        static let resetOnTextFocusLoss = "resetOnTextFocusLoss"
        static let onWindowSwitch = "onWindowSwitch"

        /// 앱·창 전환 동작이 토글·기억 옵션으로 나뉘어 있던 때의 키(ADR 0029 이전).
        /// 읽어서 `onAppSwitch`/`onWindowSwitch`로 옮긴 뒤 지운다.
        enum Old {
            static let resetOnAppSwitch = "resetOnAppSwitch"
            static let resetOnWindowSwitch = "resetOnWindowSwitch"
            static let rememberInputPerApp = "rememberInputPerApp"
            static let rememberInputPerWindow = "rememberInputPerWindow"
            static let inputMemory = "inputMemory"
            static let all = [resetOnAppSwitch, resetOnWindowSwitch, rememberInputPerApp, rememberInputPerWindow, inputMemory]
        }

        /// 한/영 고정 모델(ADR 0013 이전)의 키. 출시 전이라 이전 없이 지운다.
        static let legacy = ["koreanColor", "englishColor"] + Old.all
    }

    private let defaults: UserDefaults
    private var observers: [(KeyHueSettings, KeyHueSettings) -> Void] = []

    public private(set) var settings: KeyHueSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
        // 이전 버전이 모든 키를 저장해 둔 경우를 정리한다(기본값과 같은 키 삭제, 레거시 키 삭제).
        Key.legacy.forEach(defaults.removeObject(forKey:))
        save(settings)
    }

    /// 변경 후 값이 달라졌을 때만 저장하고 observer에 (old, new)를 전달한다.
    public func update(_ change: (inout KeyHueSettings) -> Void) {
        var next = settings
        change(&next)
        next.barHeight = KeyHueSettings.clampedBarHeight(next.barHeight)
        next.barOpacity = KeyHueSettings.clampedBarOpacity(next.barOpacity)
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
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func color(_ key: String, _ fallback: RGBAColor) -> RGBAColor {
            defaults.string(forKey: key).flatMap(RGBAColor.init(hex:)) ?? fallback
        }
        s.appLanguage = defaults.string(forKey: Key.appLanguage).flatMap(AppLanguage.init(rawValue:)) ?? s.appLanguage
        s.showDockIcon = bool(Key.showDockIcon, s.showDockIcon)
        s.showStateBar = bool(Key.showStateBar, s.showStateBar)
        s.barHeight = KeyHueSettings.clampedBarHeight(double(Key.barHeight, s.barHeight))
        s.barPosition = defaults.string(forKey: Key.barPosition).flatMap(BarPosition.init(rawValue:)) ?? s.barPosition
        s.barOpacity = KeyHueSettings.clampedBarOpacity(double(Key.barOpacity, s.barOpacity))
        let storedColors = defaults.dictionary(forKey: Key.sourceColors) as? [String: String] ?? [:]
        s.sourceColors = storedColors.compactMapValues(RGBAColor.init(hex:))
        s.capsLockColor = color(Key.capsLockColor, s.capsLockColor)
        s.unknownColor = color(Key.unknownColor, s.unknownColor)
        s.tintMenuBarIcon = bool(Key.tintMenuBarIcon, s.tintMenuBarIcon)
        let migrated = migratedSwitchBehaviors(from: defaults)
        s.onAppSwitch = defaults.string(forKey: Key.onAppSwitch).flatMap(SwitchBehavior.init(rawValue:)) ?? migrated.app
        s.onWindowSwitch = defaults.string(forKey: Key.onWindowSwitch).flatMap(SwitchBehavior.init(rawValue:)) ?? migrated.window
        s.resetOnEscape = bool(Key.resetOnEscape, s.resetOnEscape)
        s.defaultSourceID = defaults.string(forKey: Key.defaultSourceID).flatMap { $0.isEmpty ? nil : $0 }
        s.displayPolicy = defaults.string(forKey: Key.displayPolicy).flatMap(DisplayPolicy.init(rawValue:)) ?? s.displayPolicy
        s.showHUD = bool(Key.showHUD, s.showHUD)
        s.resetOnTextFocusLoss = bool(Key.resetOnTextFocusLoss, s.resetOnTextFocusLoss)
        return s
    }

    /// 옛 키 → 새 동작. 기억이 켜져 있었으면 복원, 아니면 초기화 토글에 따라 전환/그대로.
    /// 옛 키가 없으면(새로 설치) 기본값인 그대로 두기가 된다.
    static func migratedSwitchBehaviors(from defaults: UserDefaults) -> (app: SwitchBehavior, window: SwitchBehavior) {
        let mode = defaults.string(forKey: Key.Old.inputMemory)
            ?? (defaults.bool(forKey: Key.Old.rememberInputPerWindow) ? "perWindow"
                : defaults.bool(forKey: Key.Old.rememberInputPerApp) ? "perApp" : "off")
        let app: SwitchBehavior = mode != "off" ? .restoreLast
            : defaults.bool(forKey: Key.Old.resetOnAppSwitch) ? .switchToDefault : .keep
        let window: SwitchBehavior = mode == "perWindow" ? .restoreLast
            : defaults.bool(forKey: Key.Old.resetOnWindowSwitch) ? .switchToDefault : .keep
        return (app, window)
    }

    private func save(_ s: KeyHueSettings) {
        let d = KeyHueSettings()
        store(Key.appLanguage, s.appLanguage, d.appLanguage) { $0.rawValue }
        store(Key.showDockIcon, s.showDockIcon, d.showDockIcon)
        store(Key.showStateBar, s.showStateBar, d.showStateBar)
        store(Key.barHeight, s.barHeight, d.barHeight)
        store(Key.barPosition, s.barPosition, d.barPosition) { $0.rawValue }
        store(Key.barOpacity, s.barOpacity, d.barOpacity)
        store(Key.sourceColors, s.sourceColors, d.sourceColors) { $0.mapValues(\.hexString) }
        store(Key.capsLockColor, s.capsLockColor, d.capsLockColor) { $0.hexString }
        store(Key.unknownColor, s.unknownColor, d.unknownColor) { $0.hexString }
        store(Key.tintMenuBarIcon, s.tintMenuBarIcon, d.tintMenuBarIcon)
        store(Key.onAppSwitch, s.onAppSwitch, d.onAppSwitch) { $0.rawValue }
        store(Key.resetOnEscape, s.resetOnEscape, d.resetOnEscape)
        store(Key.defaultSourceID, s.defaultSourceID, d.defaultSourceID) { $0 ?? "" }
        store(Key.displayPolicy, s.displayPolicy, d.displayPolicy) { $0.rawValue }
        store(Key.showHUD, s.showHUD, d.showHUD)
        store(Key.resetOnTextFocusLoss, s.resetOnTextFocusLoss, d.resetOnTextFocusLoss)
        store(Key.onWindowSwitch, s.onWindowSwitch, d.onWindowSwitch) { $0.rawValue }
    }

    private func store<T: Equatable>(_ key: String, _ value: T, _ fallback: T, encode: (T) -> Any = { $0 }) {
        if value == fallback {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(encode(value), forKey: key)
        }
    }
}
