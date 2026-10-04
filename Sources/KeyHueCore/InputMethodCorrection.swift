import Foundation

/// How the input method corrects a word typed in the wrong language (ADR 0064).
public enum CorrectionMode: String, CaseIterable, Sendable {
    /// Never correct.
    case off
    /// Correct only when the user switches to Hangul right after the word. Default.
    case manual
    /// Correct at Space and select Hangul.
    case automatic
}

/// The correction setting is owned by the utility (`KeyHueSettings`) and read by
/// the input method, a separate process, from the utility's preferences (ADR 0064).
public enum InputMethodCorrection {
    /// The utility's preferences domain.
    public static let preferencesDomain = "io.github.sejoung.keyhue"
    /// Posted by the utility when the setting changes. No payload.
    public static let settingsChanged = "io.github.sejoung.keyhue.inputmethod.correction-settings-changed"

    public enum Key {
        public static let mode = "inputMethodCorrection"
        public static let excludedApps = "correctionExcludedApps"
        public static let ignoredWords = "correctionIgnoredWords"
        public static let recordUndone = "recordUndoneCorrections"
    }

    /// What the input method needs from the utility's settings.
    public struct Values: Equatable, Sendable {
        public var mode: CorrectionMode
        public var excludedApps: Set<String>
        /// The user's exception words (ADR 0065).
        public var ignoredWords: Set<String>
        /// Record undone corrections on this Mac (ADR 0065, off by default).
        public var recordUndone: Bool
    }

    /// The shipped list of reported false positives (ADR 0065), in the input
    /// method's bundle; the measurement tool reads the same file.
    public static let reportedWordsResource = (name: "reported-words", extension: "txt", subdirectory: "Mistype")

    /// One word per line; blank lines and `#` comments are skipped.
    public static func reportedWords(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Terminals and code editors: commands and identifiers look like mistyped Korean.
    public static let defaultExcludedApps = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4", "com.google.android.studio",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion"
    ]

    /// nil when the stored value is malformed (the caller uses the default).
    static func mode(from raw: Any) -> CorrectionMode? {
        (raw as? String).flatMap(CorrectionMode.init(rawValue:))
    }

    /// nil when the stored value is not a list. Blank entries are dropped.
    static func excludedApps(from raw: Any) -> [String]? {
        guard let list = raw as? [Any] else { return nil }
        return list.compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// What the input method needs, read from the utility's stored values with
    /// the same rules as `SettingsStore`. Missing or malformed values use defaults.
    public static func read(mode: Any?, excludedApps: Any?, ignoredWords: Any?, recordUndone: Any?) -> Values {
        Values(mode: mode.flatMap(Self.mode(from:)) ?? .manual,
               excludedApps: Set(excludedApps.flatMap(Self.excludedApps(from:)) ?? defaultExcludedApps),
               ignoredWords: Set(ignoredWords.flatMap(Self.words(from:)) ?? []),
               recordUndone: recordUndone.flatMap(SettingsStore.bool(from:)) ?? false)
    }

    /// nil when the stored value is not a list. Blank entries are dropped.
    static func words(from raw: Any) -> [String]? {
        excludedApps(from: raw)
    }
}
