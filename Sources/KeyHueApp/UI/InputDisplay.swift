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

extension SwitchBehavior {
    /// 메뉴와 설정 창이 같은 제목을 쓴다. 기본 입력 소스로 전환은 그 이름을 담는다.
    func title(defaultName: String) -> String {
        switch self {
        case .keep: return L("Keep As Is")
        case .switchToDefault: return L("Switch to %@", defaultName)
        case .restoreLast: return L("Restore Last Input Source")
        }
    }
}

extension BarPosition {
    var title: String {
        switch self {
        case .top: return L("Top")
        case .bottom: return L("Bottom")
        case .left: return L("Left")
        case .right: return L("Right")
        }
    }
}

/// 메뉴와 설정 창이 같은 안내를 보여 준다.
enum SharedText {
    static var inputMonitoringRequired: String { L("Input Monitoring access is required.") }

    static var routingDetails: String {
        L("ABC or the system 2-Set Korean selected from a KeyHue mode is redirected to the other KeyHue mode, including a manual selection, and both are shown in gray. Other languages are kept. Use Pause Integration and Switch to ABC to leave the pair. Very fast typing may arrive before macOS reports the switch.")
    }

    static func windowSwitchStalled(in app: String) -> String {
        L("KeyHue couldn't subscribe to %@'s Accessibility notifications, so it can't see window switches. Switching to another app and back tries again.", app)
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
