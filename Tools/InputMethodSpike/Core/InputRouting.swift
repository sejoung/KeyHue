import KeyHueCore

/// 입력기로 들어온 이벤트를 어떻게 처리할지. 조합 중인 글자를 잃지 않는 것이 원칙이다:
/// 공백은 조합과 함께 확정하고, 다른 경계 이벤트는 먼저 확정한 뒤 앱에 넘긴다.
public enum InputRoute: Equatable, Sendable {
    /// 조합에 넣는 글자 키
    case compose(Character)
    /// 조합 중인 키 하나를 지운다(조합이 없으면 앱에 넘긴다)
    case backspace
    /// 공백은 남은 조합과 함께 한 번 확정한다. marked text에서 단순 전달하면
    /// Cocoa가 조합 확정만 수행하고 첫 Space를 소비할 수 있다.
    case commitSpace
    /// 조합을 확정하고 이벤트는 앱이 처리한다(방향키·Tab·Return·Esc·기호·단축키)
    case commitAndPass
}

public enum InputRouting {
    static let backspaceKeyCode: UInt16 = 51

    /// - Parameters:
    ///   - otherModifiers: ⌘·⌃·⌥ 중 하나라도 눌렸다. 단축키는 조합하지 않는다.
    public static func route(keyCode: UInt16, shift: Bool, capsLock: Bool, otherModifiers: Bool,
                             mode: ProbeSession.Mode) -> InputRoute {
        if otherModifiers { return .commitAndPass }
        if keyCode == backspaceKeyCode { return .backspace }
        if keyCode == 49 { return .commitSpace }
        let key = MistypeKeyMap.key(keyCode: Int64(keyCode), shift: shift, otherModifiers: false)
        guard case .letter(let letter) = key else { return .commitAndPass }
        // Caps Lock은 영문에만 반영한다. 한글 쌍자음은 Shift로만 만든다.
        if mode == .latin, capsLock {
            return .compose(Character(shift ? letter.lowercased() : letter.uppercased()))
        }
        return .compose(letter)
    }
}

extension InputRouting {
    /// 클릭은 커서를 옮길 수 있다. 앱이 클릭을 처리하기 **전에** 조합을 확정한다.
    public static func routeMouseDown() -> InputRoute { .commitAndPass }
}

extension ProbeSession {
    /// 판단한 경로를 조합에 적용한다. `handled == false`면 이벤트를 앱에 넘긴다.
    public mutating func handle(_ route: InputRoute) -> Result {
        switch route {
        case .compose(let key): return letter(key)
        case .backspace: return backspace()
        case .commitSpace:
            let pending = finish().compactMap { action -> String? in
                if case .commit(let text) = action { return text }
                return nil
            }.joined()
            return Result(actions: [.commit(pending + " ")], handled: true)
        case .commitAndPass: return Result(actions: finish(), handled: false)
        }
    }
}
