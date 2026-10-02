import Carbon
import Foundation
import KeyHueCore

/// macOS 26 keeps third-party mode membership separately from the legacy TIS
/// properties. KeyHue only reads it: the user adds and removes the modes in
/// System Settings, and macOS rejects this domain's writes from KeyHue anyway.
/// Compatibility is limited to this observed OS/schema and our IDs.
@MainActor
final class InputMethodSourcePreferences {
    static let shared = InputMethodSourcePreferences()
    static let ownedIDs = [InputMethodManager.bundleID, InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
    static let domain = "com.apple.inputsources" as CFString
    static let key = "AppleEnabledThirdPartyInputSources" as CFString
    let isSupported: Bool
    private let read: () -> Any?
    private var hasCache = false
    private var cached: [[String: Any]]?

    init(isSupported: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
         read: @escaping () -> Any? = {
             guard CFPreferencesAppSynchronize(domain) else { return NSNull() }
             return CFPreferencesCopyAppValue(key, domain)
         }) {
        self.isSupported = isSupported
        self.read = read
    }

    func invalidate() { hasCache = false; cached = nil }

    var enabledIDs: [String]? {
        entries.map { $0.compactMap(Self.ownedID) }
    }

    private var entries: [[String: Any]]? {
        guard isSupported else { return nil }
        if hasCache { return cached }
        hasCache = true
        let value = read()
        guard value == nil || value is [[String: Any]] else { return nil }
        let candidate = value as? [[String: Any]] ?? []
        // An unknown mode under our bundle may belong to a future version.
        // Fall back to TIS properties; unrelated entries are opaque.
        guard candidate.allSatisfy({ $0["Bundle ID"] as? String != InputMethodManager.bundleID || Self.ownedID($0) != nil }) else { return nil }
        cached = candidate
        return candidate
    }

    private static func ownedID(_ entry: [String: Any]) -> String? {
        guard entry["Bundle ID"] as? String == InputMethodManager.bundleID else { return nil }
        if entry["InputSourceKind"] as? String == "Keyboard Input Method", entry["Input Mode"] == nil {
            return InputMethodManager.bundleID
        }
        guard entry["InputSourceKind"] as? String == "Input Mode",
              let id = entry["Input Mode"] as? String,
              id == InputMethodIntegration.hangulID || id == InputMethodIntegration.latinID else { return nil }
        return id
    }
}
