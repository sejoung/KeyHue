import Carbon
import CoreGraphics
import Foundation

/// The user's "Select the previous input source" shortcut (system hot key 60).
/// KeyHue reads it and never edits the shortcut settings (ADR 0062).
struct InputSourceShortcut: Equatable {
    let keyCode: UInt16
    let flags: UInt64

    static let previousSourceHotKey = "60"
    /// Set on every event KeyHue posts; its own tap ignores these (ADR 0062).
    static let eventMarker: Int64 = 0x4B48_5245 // "KHRE"
    private static let allowedFlags = CGEventFlags([.maskCommand, .maskControl, .maskAlternate, .maskShift]).rawValue
    /// Modifier keys in press order; released in reverse.
    private static let modifierKeys: [(CGEventFlags, UInt16)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]

    init(keyCode: UInt16, flags: UInt64) {
        self.keyCode = keyCode
        self.flags = flags
    }

    /// Only an enabled standard key + modifier shortcut. Caps Lock and Fn switching
    /// are not hot keys and are never synthesized.
    init?(symbolicHotKeys: [String: Any]) {
        guard let entry = symbolicHotKeys[Self.previousSourceHotKey] as? [String: Any],
              entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
              (0..<128).contains(parameters[1].intValue), parameters[2].int64Value > 0 else { return nil }
        let flags = parameters[2].uint64Value
        guard flags & ~Self.allowedFlags == 0 else { return nil }
        self.init(keyCode: parameters[1].uint16Value, flags: flags)
    }

    var modifierKeyCodes: [UInt16] {
        Self.modifierKeys.filter { flags & $0.0.rawValue != 0 }.map(\.1)
    }

    /// Key down/up with full modifier transitions, as global shortcuts require.
    func events(marker: Int64) -> [CGEvent]? {
        var held = CGEventFlags()
        var downs: [CGEvent] = []
        var ups: [CGEvent] = []
        for (flag, code) in Self.modifierKeys where flags & flag.rawValue != 0 {
            guard let press = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let release = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return nil }
            release.flags = held
            held.insert(flag)
            press.flags = held
            downs.append(press)
            ups.insert(release, at: 0)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return nil }
        down.flags = CGEventFlags(rawValue: flags)
        up.flags = CGEventFlags(rawValue: flags)
        let all = downs + [down, up] + ups
        for event in all { event.setIntegerValueField(.eventSourceUserData, value: marker) }
        return all
    }
}

/// Presses the previous-source shortcut so the front client selects the source
/// in its own process. Events carry a marker that KeyHue's own tap ignores.
@MainActor
final class InputSourceShortcutPoster {
    private var shortcut: InputSourceShortcut? {
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        return (hotKeys as? [String: Any]).flatMap(InputSourceShortcut.init(symbolicHotKeys:))
    }

    /// No event is sent into a secure field, without posting permission, or without a usable shortcut.
    var unavailableReason: String? {
        if IsSecureEventInputEnabled() { return "secure input" }
        if !CGPreflightPostEventAccess() { return "no event posting permission" }
        if shortcut == nil { return "previous-source shortcut unavailable" }
        return nil
    }

    func press() -> Bool {
        guard let events = shortcut?.events(marker: InputSourceShortcut.eventMarker) else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }
}
