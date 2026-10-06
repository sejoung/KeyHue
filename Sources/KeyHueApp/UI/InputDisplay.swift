import KeyHueCore

extension InputState {
    /// 메뉴·설정 창에 표시할 이름. 입력 소스 이름은 macOS가 OS 언어로 준다.
    var displayName: String {
        switch self {
        case .source(let info): return info.displayName
        case .capsLock: return L("Caps Lock")
        case .unknown: return L("Unknown")
        }
    }
}

/// 색을 지정할 수 있는 대상: 입력 소스 하나 또는 Caps Lock.
enum ColorTarget: Hashable {
    case source(InputSourceInfo)
    case capsLock

    var title: String {
        switch self {
        case .source(let info): return info.displayName
        case .capsLock: return L("Caps Lock")
        }
    }

    func color(in settings: KeyHueSettings) -> RGBAColor {
        switch self {
        case .source(let info): return settings.color(for: info)
        case .capsLock: return settings.capsLockColor
        }
    }

    func setColor(_ color: RGBAColor, in settings: inout KeyHueSettings) {
        switch self {
        case .source(let info): settings.setColor(color, for: info)
        case .capsLock: settings.capsLockColor = color
        }
    }
}
