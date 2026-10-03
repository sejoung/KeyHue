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
    public var pendingText: String? { keys.isEmpty ? nil : composed }
    /// 앱이 우리가 표시한 조합 범위를 한 번이라도 알려 줬다. 알려 주지 않는 앱에서는 앱 상태와 맞추지 않는다
    /// (그런 앱에서 "조합 없음"을 믿으면 키마다 조합이 끊긴다).
    private var clientReportsMarkedText = false

    public init() {}

    /// Called at key delivery even when IMK omitted a mode callback. nil means
    /// this source is not owned by the spike and the key must be passed through.
    public mutating func synchronize(inputSourceID: String?) -> [Action]? {
        guard let inputSourceID, let selected = Mode(inputSourceID: inputSourceID) else { return nil }
        return select(selected)
    }

    /// A source can change without another IMK event/deactivation. Only finish
    /// the old composition when the client still contains that exact mark.
    /// The next IMK event, rather than a notification, selects the engine mode.
    public mutating func finishAfterSourceChange(inputSourceID: String?, verifiedMarkedText: String?) -> [Action] {
        guard let inputSourceID, !inputSourceID.isEmpty,
              Mode(inputSourceID: inputSourceID) != mode,
              let pendingText, verifiedMarkedText == pendingText else { return [] }
        return finish()
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

    /// 조합을 표시한 직후 앱이 조합 범위를 갖고 있는지 알린다.
    public mutating func observeClientMarkedText(_ hasMarkedText: Bool) {
        if hasMarkedText { clientReportsMarkedText = true }
    }

    /// 키를 처리하기 전에 앱 상태와 맞춘다. 앱이 조합 중인 글자를 이미 확정했거나 버렸다면(마우스·포커스 처리,
    /// 일부 앱·베타 OS) 우리 쪽 조합도 확정하지 않고 비운다. 그렇지 않으면 다음 키가 앞 글자를 다시 넣거나
    /// 버려진 글자를 되살린다. - Returns: 비웠으면 true.
    @discardableResult
    public mutating func reconcile(clientHasMarkedText: Bool) -> Bool {
        guard clientReportsMarkedText, !keys.isEmpty, !clientHasMarkedText else { return false }
        keys = ""
        return true
    }

    /// 앱이 조합 취소를 요청했다. 마지막 글자를 잃지 않도록 버리지 않고 확정한다.
    public mutating func cancelComposition() -> [Action] {
        finish()
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
