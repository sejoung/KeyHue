import Foundation

/// Only the installed spike's two explicit TIS mode IDs are recognized. A future
/// production input method must opt into this contract separately (ADR 0049).
public enum InputMethodIntegration {
    /// Parent bundle identifier shared by the utility and its embedded input method.
    public static let bundleID = "io.github.sejoung.keyhue.inputmethod.spike"
    public static let connectionName = "KeyHueInputMethodSpike_Connection"
    public static let abcID = "com.apple.keylayout.ABC"
    public static let hangulID = bundleID + ".Hangul"
    public static let latinID = bundleID + ".Latin"
    /// The system layout KeyHue's Korean mode replaces. Other Korean layouts stay as they are.
    public static let systemHangulID = "com.apple.inputmethod.Korean.2SetKorean"
    /// Distributed notification from the input method server when a client session is
    /// activated or receives a mode callback. The object is the mode ID only (ADR 0062).
    public static let sessionAcknowledgement = "io.github.sejoung.keyhue.inputmethod.session-acknowledged"

    /// While both KeyHue modes are integrated, these are only detours on the way to
    /// a KeyHue mode: routed when chosen from one (ADR 0071, 0082).
    public static let detourIDs: Set<String> = [abcID, systemHangulID]
    /// A detour's default color while integrated, so landing on one does not look
    /// like the KeyHue mode of the same language (2026-10-07: ABC was the same blue).
    public static let detourColor = RGBAColor(hex: "#8E8E93")!

    /// Settings as shown: detours gray while integrated, unless the user chose a color.
    /// A copy for display only; the saved settings are unchanged (ADR 0082).
    public static func displaySettings(_ settings: KeyHueSettings, integrated: Bool) -> KeyHueSettings {
        guard integrated else { return settings }
        var result = settings
        for id in detourIDs where result.sourceColors[id] == nil {
            result.sourceColors[id] = detourColor
        }
        return result
    }

    public static func isAvailable(in sources: [InputSourceInfo]) -> Bool {
        let ids = Set(sources.map(\.id))
        return ids.contains(hangulID) && ids.contains(latinID)
    }

    /// Memory keeps the ID that was current when recorded, which may predate or
    /// outlive integration. Read it as the matching member of the pair in use now.
    public static func sourceID(_ id: String, settings: KeyHueSettings, sources: [InputSourceInfo]) -> String {
        if settings.integrateInputMethod && isAvailable(in: sources) {
            switch id {
            case abcID: return latinID
            case systemHangulID: return hangulID
            default: return id
            }
        }
        let ids = Set(sources.map(\.id))
        switch id {
        case hangulID where ids.contains(systemHangulID): return systemHangulID
        case latinID where ids.contains(abcID): return abcID
        default: return id
        }
    }

    /// Effective settings are a copy: disabling integration restores the saved preference.
    /// A saved default is read as the matching member of the pair in use, like memory.
    public static func effectiveSettings(_ settings: KeyHueSettings, sources: [InputSourceInfo]) -> KeyHueSettings {
        var result = settings
        guard settings.integrateInputMethod, isAvailable(in: sources) else {
            if let id = settings.defaultSourceID, id == hangulID || id == latinID {
                result.defaultSourceID = sourceID(id, settings: settings, sources: sources)
            }
            return result
        }
        if settings.defaultSourceID == nil || settings.defaultSourceID == abcID {
            result.defaultSourceID = latinID
        } else if settings.defaultSourceID == systemHangulID {
            result.defaultSourceID = hangulID
        }
        return result
    }

    /// The saved default is missing only if what it is read as is not enabled.
    /// A default read as the matching member of the pair in use is not missing.
    public static func isDefaultUnavailable(settings: KeyHueSettings, sources: [InputSourceInfo]) -> Bool {
        guard settings.defaultSourceID != nil,
              let effective = effectiveSettings(settings, sources: sources).defaultSourceID else { return false }
        return !sources.contains { $0.id == effective }
    }

    public static func automaticSource(settings: KeyHueSettings, sources: [InputSourceInfo]) -> InputSourceInfo? {
        var automatic = settings
        automatic.defaultSourceID = nil
        return defaultSource(settings: automatic, sources: sources)
    }

    /// The login window and password fields select ABC themselves and put it back
    /// at once. Routing that ABC was taken for a system overwrite and turned the
    /// user's routing option off on every screen lock (ADR 0071).
    public static func routesABC(frontBundleID: String?, secureInput: Bool) -> Bool {
        !secureInput && frontBundleID != "com.apple.loginwindow"
    }

    public static func defaultSource(settings: KeyHueSettings, sources: [InputSourceInfo]) -> InputSourceInfo? {
        DefaultInputSourcePicker.pick(from: sources, preferredID: effectiveSettings(settings, sources: sources).defaultSourceID)
    }
}
