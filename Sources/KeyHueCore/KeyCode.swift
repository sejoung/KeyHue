import Foundation

/// macOS virtual key codes (ANSI key positions), the same values as Carbon's
/// `kVK_*` constants, which this module does not import. One table for the
/// utility, the input method and their tests.
public enum KeyCode {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    /// Backspace.
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    /// The 1 key: Shift+1 is "!".
    public static let one: UInt16 = 18
    /// Shift, Control, Option, Command, Caps Lock, Fn and their right-hand keys.
    public static let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}
