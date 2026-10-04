import Foundation

/// The key the user presses to fix the word before the caret or the selection
/// (ADR 0068). The input method receives it itself, so it must be a key the input
/// method can see and that never types text. Stored as text, e.g. "option+36".
public struct CorrectionShortcut: Equatable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Display and storage order (Apple's: ⌃⌥⇧⌘).
        static let ordered: [(Modifiers, name: String, symbol: String)] = [
            (.control, "control", "⌃"), (.option, "option", "⌥"), (.shift, "shift", "⇧"), (.command, "command", "⌘")
        ]
    }

    public let keyCode: UInt16
    public let modifiers: Modifiers

    /// ⌥↩: rarely bound by apps or global launchers.
    public static let `default` = CorrectionShortcut(keyCode: 36, modifiers: .option)

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(rawValue: String) {
        var parts = rawValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let code = UInt16(parts.removeLast()), code < 128 else { return nil }
        var modifiers: Modifiers = []
        for part in parts {
            guard let entry = Modifiers.ordered.first(where: { $0.name == part }) else { return nil }
            modifiers.insert(entry.0)
        }
        self.init(keyCode: code, modifiers: modifiers)
    }

    public var rawValue: String {
        (Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.name) + [String(keyCode)]).joined(separator: "+")
    }

    private static let space: UInt16 = 49
    private static let returnKey: UInt16 = 36
    /// Shift, Control, Option, Command, Caps Lock, Fn and their right-hand keys.
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// ⌥ or ⌃ with a key, or ⇧ with Space or Return. ⌘ keys are the app's menu
    /// shortcuts and often never reach the input method; a plain or ⇧ letter types
    /// text; ⌃Space and ⌃⌥Space are the system's input source shortcuts.
    public var isAllowed: Bool {
        guard !Self.modifierKeys.contains(keyCode), !modifiers.contains(.command) else { return false }
        if keyCode == Self.space, modifiers == .control || modifiers == [.control, .option] { return false }
        if !modifiers.isDisjoint(with: [.control, .option]) { return true }
        return modifiers == .shift && (keyCode == Self.space || keyCode == Self.returnKey)
    }

    /// Exactly these modifiers: ⌥⇧↩ is not ⌥↩.
    public func matches(keyCode: UInt16, modifiers: Modifiers) -> Bool {
        keyCode == self.keyCode && modifiers == self.modifiers
    }

    private static let keyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12"
    ]

    /// ⌥↩, ⌃⇧Space, ⌃T.
    public var displayName: String {
        let symbols = Modifiers.ordered.filter { modifiers.contains($0.0) }.map(\.symbol).joined()
        let key: String
        if let name = Self.keyNames[keyCode] {
            key = name
        } else if case .letter(let letter) = MistypeKeyMap.key(keyCode: Int64(keyCode), shift: false, otherModifiers: false) {
            key = letter.uppercased()
        } else {
            key = "#\(keyCode)"
        }
        return symbols + key
    }
}

extension CorrectionShortcut: CustomStringConvertible {
    /// The stored text, also used in the settings log.
    public var description: String { rawValue }
}
