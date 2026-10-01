import Foundation

/// 키 하나를 단어 판정에 쓰는 종류로 나눈 것(ADR 0041). 글자 내용은 영문자 키만 남긴다.
public enum MistypeKey: Equatable, Sendable {
    /// 영문자 키(QWERTY 글자, 대문자 = Shift)
    case letter(Character)
    /// 단어가 끝났다: 스페이스, 리턴, 탭
    case boundary
    /// 단어 끝의 문장 부호(. , ; ' / !). 뒤에 글자가 더 오면 판정하지 않는다.
    case punctuation
    /// 지우기(백스페이스, 앞으로 지우기). 고친 단어는 판정하지 않는다.
    case edit
    /// 그 밖의 키(숫자, 화살표, 단축키 등). 단어를 버린다.
    case other
}

/// macOS 가상 키 코드(ANSI 배열 위치)를 `MistypeKey`로 바꾼다.
/// 키 코드는 입력 소스와 상관없이 같은 위치의 키이므로, 한글 모드에서도 같은 표로 읽는다.
public enum MistypeKeyMap {
    private static let letters: [Int64: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]
    private static let boundaries: Set<Int64> = [49, 36, 76, 48] // space, return, keypad enter, tab
    private static let edits: Set<Int64> = [51, 117] // delete, forward delete
    /// , . ; ' /
    private static let punctuation: Set<Int64> = [43, 47, 41, 39, 44]
    private static let one: Int64 = 18

    /// - shift: Shift를 누르고 있다(Caps Lock은 따로 본다).
    /// - otherModifiers: ⌘·⌃·⌥ 중 하나라도 눌렀다(단축키).
    public static func key(keyCode: Int64, shift: Bool, otherModifiers: Bool) -> MistypeKey {
        guard !otherModifiers else { return .other }
        if let letter = letters[keyCode] {
            return .letter(shift ? Character(letter.uppercased()) : letter)
        }
        if boundaries.contains(keyCode) { return .boundary }
        if edits.contains(keyCode) { return .edit }
        if punctuation.contains(keyCode) || (shift && keyCode == one) { return .punctuation }
        return .other
    }
}

/// 단어 하나를 이루는 키를 모아 두었다가 판정한다(ADR 0041, 1a단계: 경고만).
///
/// - 치는 중(ADR 0042): 글자 키마다 앞부분으로 판정한다(검출기에 영어 접두사가 있을 때). 한 단어에 한 번만 알린다.
/// - 단어 끝: 치는 중에 알리지 않은 단어를 공백에서 단어 전체로 다시 판정한다.
///
/// 판정하지 않고 버리는 경우(오탐을 줄이려고 확실한 단어만 본다):
/// - 단어 중간에 지웠다(오타를 고친 단어), 문장 부호 뒤에 글자가 더 왔다(didn't, a.b).
/// - 단어 중간에 입력 모드가 바뀌었다(API를), 지원하지 않는 입력 소스이거나 Caps Lock이 켜져 있다(`mode`가 nil).
/// - 숫자·화살표·단축키(다음 단어 경계까지), 마우스 클릭·앱 전환(`reset`) 등 커서가 움직였을 수 있는 입력.
/// - `maximumKeys`보다 길다.
/// 모은 키는 메모리에만 있고, 단어가 끝나거나 버리면 곧바로 지운다.
public struct MistypeWordTracker {
    public static let maximumKeys = 40

    public let detector: MistypeDetector
    private var keys = ""
    private var mode: TypingMode?
    private var state = State.empty
    /// 이 단어는 이미 알렸다(같은 단어에서 다시 알리지 않는다).
    private var warned = false

    /// 마지막으로 돌려준 판정이 치는 중(단어가 끝나기 전)에 나왔다. 메시지에 "…"를 붙이는 데 쓴다.
    public private(set) var lastWarningWasWhileTyping = false

    private enum State {
        case empty
        /// 글자를 모으는 중
        case collecting
        /// 문장 부호로 끝났다. 다음 키가 단어 경계여야 판정한다.
        case ended
        /// 이 단어는 판정하지 않는다(다음 단어 경계까지 무시).
        case discarded
    }

    public init(detector: MistypeDetector) {
        self.detector = detector
    }

    /// 모으는 중인 키 수(테스트용).
    public var pendingKeyCount: Int { keys.count }

    /// 키 하나. 단어가 끝났고 잘못된 언어로 친 것 같으면 판정을 돌려준다.
    /// - mode: 키를 칠 때의 입력 모드. 지원하지 않으면 nil.
    public mutating func key(_ key: MistypeKey, mode: TypingMode?) -> MistypeVerdict? {
        guard let mode else {
            // 단어 중간에 Caps Lock이나 지원하지 않는 입력 소스가 끼면 그 단어는 버린다(뒤 글자를 새 단어로 보지 않는다).
            if state == .empty { reset() } else { discard() }
            return nil
        }
        switch key {
        case .letter(let letter):
            switch state {
            case .empty:
                self.mode = mode
                keys = String(letter)
                state = .collecting
            case .collecting where mode == self.mode && keys.count < Self.maximumKeys:
                keys.append(letter)
            case .collecting, .ended:
                discard()
                return nil
            case .discarded:
                return nil
            }
            guard !warned else { return nil }
            let verdict = detector.judgeEarly(keys: keys, typedIn: mode)
            guard verdict != .keep else { return nil }
            warned = true
            lastWarningWasWhileTyping = true
            return verdict
        case .boundary:
            defer { reset() }
            guard state == .collecting || state == .ended, !warned, let wordMode = self.mode else { return nil }
            let verdict = detector.judge(keys: keys, typedIn: wordMode)
            guard verdict != .keep else { return nil }
            lastWarningWasWhileTyping = false
            return verdict
        case .punctuation:
            if state == .collecting { state = .ended }
        case .edit:
            // 단어가 끝난 직후의 지우기는 공백을 지워 앞 단어와 이어 붙인다. 이어서 치는 글자는 온전한 단어가 아니다.
            discard()
        case .other:
            // 숫자·화살표 뒤에 이어 친 글자는 온전한 단어가 아닐 수 있다(3개, 커서를 옮겨 단어 가운데에 친 글자).
            discard()
        }
        return nil
    }

    /// 커서가 움직였을 수 있다(마우스 클릭, 앱 전환 등). 모은 키를 버린다.
    public mutating func reset() {
        keys = ""
        mode = nil
        state = .empty
        warned = false
    }

    private mutating func discard() {
        keys = ""
        state = .discarded
    }
}

/// 이 기능을 쓸 수 있는 입력 소스(ADR 0041). 두벌식과 QWERTY 영문 배열에서만 의미가 있다.
public enum MistypeSupport {
    public static let hangulSourceIDs: Set<String> = ["com.apple.inputmethod.Korean.2SetKorean"]
    /// 키 위치가 QWERTY인 영문 배열
    public static let latinSourceIDs: Set<String> = [
        "com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.USExtended",
        "com.apple.keylayout.British", "com.apple.keylayout.British-PC", "com.apple.keylayout.Australian",
        "com.apple.keylayout.Canadian", "com.apple.keylayout.Irish", "com.apple.keylayout.USInternational-PC"
    ]

    public static func mode(forSourceID id: String) -> TypingMode? {
        if hangulSourceIDs.contains(id) { return .hangul }
        if latinSourceIDs.contains(id) { return .latin }
        return nil
    }

    /// 두벌식과 QWERTY 영문 배열이 둘 다 켜져 있을 때만 쓸 수 있다(설정에 보인다).
    public static func isAvailable(enabledSourceIDs: [String]) -> Bool {
        enabledSourceIDs.contains(where: hangulSourceIDs.contains) && enabledSourceIDs.contains(where: latinSourceIDs.contains)
    }

    /// 경고에 쓸 "의도한 언어"의 입력 소스. 켜진 순서에서 첫 번째.
    public static func intendedSourceID(for verdict: MistypeVerdict, enabledSourceIDs: [String]) -> String? {
        switch verdict {
        case .keep: return nil
        case .meantHangul: return enabledSourceIDs.first(where: hangulSourceIDs.contains)
        case .meantLatin: return enabledSourceIDs.first(where: latinSourceIDs.contains)
        }
    }
}
