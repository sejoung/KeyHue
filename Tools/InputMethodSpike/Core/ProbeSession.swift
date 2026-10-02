import KeyHueCore

/// T단계의 조합 표시/확정 실험. 정식 입력기 엔진이나 자동 고침 정책이 아니다.
public struct ProbeSession {
    public enum Mode: String, Sendable {
        case hangul, latin

        /// Only the spike's explicit mode IDs are accepted; ABC/other input methods
        /// must never be inferred from their language or the previous session mode.
        public init?(inputSourceID: String) {
            switch inputSourceID {
            case InputMethodIntegration.hangulID: self = .hangul
            case InputMethodIntegration.latinID: self = .latin
            default: return nil
            }
        }
    }
    public enum Action: Equatable, Sendable {
        case mark(String)
        case commit(String)
    }
    public struct Result: Equatable, Sendable {
        public let actions: [Action]
        public let handled: Bool
    }

    public private(set) var mode: Mode = .hangul
    private var keys = ""

    public init() {}

    /// Called at key delivery even when IMK omitted a mode callback. nil means
    /// this source is not owned by the spike and the key must be passed through.
    public mutating func synchronize(inputSourceID: String?) -> [Action]? {
        guard let inputSourceID, let selected = Mode(inputSourceID: inputSourceID) else { return nil }
        return select(selected)
    }

    public mutating func select(_ mode: Mode) -> [Action] {
        // Activation and mode callbacks can repeat for the same composition.
        guard self.mode != mode else { return [] }
        let actions = finish()
        self.mode = mode
        return actions
    }

    public mutating func letter(_ key: Character) -> Result {
        guard key.isASCII && key.isLetter else { return Result(actions: finish(), handled: false) }
        if mode == .latin {
            // 앞 글자는 확정하고 현재 한 글자만 조합한다. 단어 조합 실험은 제거했다.
            let actions = finish()
            keys = String(key)
            return Result(actions: actions + [.mark(keys)], handled: true)
        }
        var actions: [Action] = []
        keys.append(key)
        let text = composed
        if mode == .hangul, text.count > 1, let last = text.last,
           let pendingKeys = Dubeolsik.keys(for: String(last)) {
            // 새 글자가 생기면 앞부분은 현재 marked text를 대체해 확정한다.
            // 받침 이동/겹받침 분리 뒤의 마지막 글자에 필요한 실제 키만 남긴다.
            // 원래 Shift 입력을 보존해 Backspace가 키 단위로 동작하게 한다.
            actions.append(.commit(String(text.dropLast())))
            keys = String(keys.suffix(pendingKeys.count))
            actions.append(.mark(String(last)))
        } else {
            actions.append(.mark(text))
        }
        return Result(actions: actions, handled: true)
    }

    public mutating func backspace() -> Result {
        guard !keys.isEmpty else { return Result(actions: [], handled: false) }
        keys.removeLast()
        return Result(actions: [.mark(composed)], handled: true)
    }

    public mutating func finish() -> [Action] {
        guard !keys.isEmpty else { return [] }
        let text = composed
        keys = ""
        return [.commit(text)]
    }

    private var composed: String {
        guard !keys.isEmpty else { return "" }
        return mode == .hangul ? Dubeolsik.compose(keys: keys).text : keys
    }
}
