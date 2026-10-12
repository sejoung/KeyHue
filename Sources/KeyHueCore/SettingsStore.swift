import Foundation

/// `KeyHueSettings`를 UserDefaults에 저장/복원한다. DB나 파일을 쓰지 않는다.
///
/// **기본값과 다른 값만 저장한다**(ADR 0014). 기본값과 같은 값은 키를 지워서, 이후 버전에서 기본값이
/// 바뀌면 사용자가 건드리지 않은 설정은 새 기본값을 따르게 한다.
@MainActor
public final class SettingsStore {
    enum Key {
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

    /// 저장하는 설정 하나: 키, 읽는 법, 쓰는 법. 읽기와 쓰기가 이 표 하나에서 나오므로 새 설정은 한 줄로
    /// 추가하고, 읽기만 하고 저장하지 않는 설정은 생길 수 없다.
    struct Field {
        let key: String
        /// 값을 읽어 넣는다. false면 형식이 깨졌다(읽을 수 있는 부분만 넣었다).
        let load: (Any, inout KeyHueSettings) -> Bool
        /// 저장할 값. 기본값과 같으면 nil이고 키를 지운다(ADR 0014).
        let save: (_ value: KeyHueSettings, _ defaults: KeyHueSettings) -> Any?

        static func value<T: Equatable>(_ key: String, _ keyPath: WritableKeyPath<KeyHueSettings, T>,
                                        parse: @escaping (Any) -> T?, encode: @escaping (T) -> Any) -> Field {
            Field(key: key, load: { raw, settings in
                guard let value = parse(raw) else { return false }
                settings[keyPath: keyPath] = value
                return true
            }, save: { settings, defaults in
                settings[keyPath: keyPath] == defaults[keyPath: keyPath] ? nil : encode(settings[keyPath: keyPath])
            })
        }

        static func bool(_ key: String, _ keyPath: WritableKeyPath<KeyHueSettings, Bool>) -> Field {
            value(key, keyPath, parse: StoredValue.bool(from:), encode: { $0 })
        }

        static func double(_ key: String, _ keyPath: WritableKeyPath<KeyHueSettings, Double>, clamp: @escaping (Double) -> Double) -> Field {
            value(key, keyPath, parse: { SettingsStore.double(from: $0).map(clamp) }, encode: { $0 })
        }

        static func choice<T: RawRepresentable & Equatable>(_ key: String, _ keyPath: WritableKeyPath<KeyHueSettings, T>) -> Field
            where T.RawValue == String {
            value(key, keyPath, parse: { ($0 as? String).flatMap(T.init(rawValue:)) }, encode: \.rawValue)
        }

        static func color(_ key: String, _ keyPath: WritableKeyPath<KeyHueSettings, RGBAColor>) -> Field {
            value(key, keyPath, parse: { ($0 as? String).flatMap(RGBAColor.init(hex:)) }, encode: \.hexString)
        }

        static func list(_ key: String, _ keyPath: WritableKeyPath<KeyHueSettings, [String]>) -> Field {
            value(key, keyPath, parse: InputMethodCorrection.excludedApps(from:), encode: { $0 })
        }
    }

    static let fields: [Field] = [
        .choice("appLanguage", \.appLanguage),
        .bool("automaticallyChecksForUpdates", \.automaticallyChecksForUpdates),
        .bool("showDockIcon", \.showDockIcon),
        .bool("showStateBar", \.showStateBar),
        .double("barHeight", \.barHeight, clamp: KeyHueSettings.clampedBarHeight),
        .choice("barPosition", \.barPosition),
        .double("barOpacity", \.barOpacity, clamp: KeyHueSettings.clampedBarOpacity),
        // 값 하나가 깨져 있어도(다른 타입, 잘못된 hex) 그 항목만 버리고 나머지 색은 살린다.
        Field(key: "sourceColors", load: { raw, settings in
            let stored = raw as? [String: Any] ?? [:]
            settings.sourceColors = stored.compactMapValues { ($0 as? String).flatMap(RGBAColor.init(hex:)) }
            return raw is [String: Any] && settings.sourceColors.count == stored.count
        }, save: { settings, defaults in
            settings.sourceColors == defaults.sourceColors ? nil : settings.sourceColors.mapValues(\.hexString)
        }),
        .color("capsLockColor", \.capsLockColor),
        .color("unknownColor", \.unknownColor),
        .bool("tintMenuBarIcon", \.tintMenuBarIcon),
        .choice("onAppSwitch", \.onAppSwitch),
        .bool("resetOnEscape", \.resetOnEscape),
        .bool("integrateInputMethod", \.integrateInputMethod),
        .bool("routeInputMethodPair", \.routeInputMethodPair),
        // 입력기도 같은 키와 규칙으로 읽는다(`InputMethodCorrection.read`).
        .choice(InputMethodCorrection.Key.mode, \.inputMethodCorrection),
        .list(InputMethodCorrection.Key.excludedApps, \.correctionExcludedApps),
        .list(InputMethodCorrection.Key.ignoredWords, \.correctionIgnoredWords),
        .bool(InputMethodCorrection.Key.recordUndone, \.recordUndoneCorrections),
        .value(InputMethodCorrection.Key.shortcut, \.correctionShortcut, parse: InputMethodCorrection.shortcut(from:), encode: \.rawValue),
        // 빈 글자는 자동(nil). 글자가 아니면 깨진 값이다.
        .value("defaultSourceID", \.defaultSourceID, parse: { raw in
            (raw as? String).map { $0.isEmpty ? nil : $0 }
        }, encode: { $0 ?? "" }),
        .choice("displayPolicy", \.displayPolicy),
        .bool("showHUD", \.showHUD),
        .bool("resetOnTextFocusLoss", \.resetOnTextFocusLoss),
        .choice("onWindowSwitch", \.onWindowSwitch),
        .bool("warnOnWrongLanguage", \.warnOnWrongLanguage),
        .bool("wrongLanguageShowsMessage", \.wrongLanguageShowsMessage)
    ]

    private let defaults: UserDefaults
    private var observers: [(KeyHueSettings, KeyHueSettings) -> Void] = []

    public private(set) var settings: KeyHueSettings
    /// 시작할 때 읽지 못해 기본값으로 대신한 키(형식이 깨진 값). 앱이 로그에 남긴다. 값 자체는 남기지 않는다.
    public let ignoredKeys: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        (self.settings, self.ignoredKeys) = Self.load(from: defaults)
        // 깨진 값은 기본값으로 읽었으므로 아래 save가 그 키를 지운다. 다음 실행에서 같은 일이 반복되지 않는다.
        // 이전 버전이 모든 키를 저장해 둔 경우를 정리한다(기본값과 같은 키 삭제, 레거시 키 삭제).
        for key in Key.legacy where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
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

    /// 값 하나가 깨져 있으면(다른 타입, 읽을 수 없는 글자) 그 항목만 기본값으로 읽는다(ADR 0043).
    /// `UserDefaults.bool/double(forKey:)`는 읽지 못한 값을 false/0으로 돌려주므로 직접 해석한다.
    private static func load(from defaults: UserDefaults) -> (KeyHueSettings, ignored: [String]) {
        var settings = KeyHueSettings()
        // 새 키가 없으면 옛 키에서 옮긴 동작을 쓴다.
        (settings.onAppSwitch, settings.onWindowSwitch) = migratedSwitchBehaviors(from: defaults)
        var ignored: [String] = []
        // 깨진 값은 그 필드만 기본값으로 남는다(색 목록은 읽을 수 있는 색을 살린다).
        for field in fields {
            guard let raw = defaults.object(forKey: field.key) else { continue }
            if !field.load(raw, &settings) { ignored.append(field.key) }
        }
        return (settings, ignored)
    }

    /// 크기·불투명도: 유한한 숫자 또는 숫자 글자. 불리언은 크기가 아니다.
    nonisolated static func double(from raw: Any) -> Double? {
        let value: Double?
        if let text = raw as? String {
            value = Double(text.trimmingCharacters(in: .whitespaces))
        } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else {
            value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
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

    /// 저장된 값과 다른 키만 쓴다. 쓰기마다 cfprefsd를 거치므로, 슬라이더를 끄는 동안 모든 키를 다시 쓰지 않는다.
    private func save(_ settings: KeyHueSettings) {
        let defaultValues = KeyHueSettings()
        for field in Self.fields {
            let stored = defaults.object(forKey: field.key)
            if let value = field.save(settings, defaultValues) {
                if (stored as? NSObject)?.isEqual(value) != true { defaults.set(value, forKey: field.key) }
            } else if stored != nil {
                defaults.removeObject(forKey: field.key)
            }
        }
    }
}
