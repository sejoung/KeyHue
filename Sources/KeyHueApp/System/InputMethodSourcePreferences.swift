import Carbon
import Foundation
import KeyHueCore

/// macOS 26 keeps third-party mode membership separately from the legacy TIS
/// mutation APIs. Compatibility is limited to this observed OS/schema and our IDs.
@MainActor
final class InputMethodSourcePreferences {
    static let shared = InputMethodSourcePreferences()
    static let ownedIDs = [InputMethodManager.bundleID, InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
    static let domain = "com.apple.inputsources" as CFString
    static let key = "AppleEnabledThirdPartyInputSources" as CFString
    let isSupported: Bool
    private let read: () -> Any?
    private let write: ([[String: Any]]) -> Bool
    private let publish: () -> Void
    private var hasCache = false
    private var cached: [[String: Any]]?

    init(isSupported: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
         read: @escaping () -> Any? = {
             guard CFPreferencesAppSynchronize(domain) else { return NSNull() }
             return CFPreferencesCopyAppValue(key, domain)
         },
         write: @escaping ([[String: Any]]) -> Bool = { entries in
             CFPreferencesSetAppValue(key, entries as CFArray, domain)
             return CFPreferencesAppSynchronize(domain)
         },
         publish: @escaping () -> Void = {
             DistributedNotificationCenter.default().postNotificationName(
                 Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                 object: nil, userInfo: nil, deliverImmediately: true)
         }) {
        self.isSupported = isSupported
        self.read = read
        self.write = write
        self.publish = publish
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
        // Refuse to overwrite its configuration; unrelated entries are opaque.
        guard candidate.allSatisfy({ $0["Bundle ID"] as? String != InputMethodManager.bundleID || Self.ownedID($0) != nil }) else { return nil }
        cached = candidate
        return candidate
    }

    @discardableResult
    func setEnabled(_ ids: [String]) throws -> Bool {
        guard isSupported else { return false }
        invalidate()
        guard let before = entries, ids.allSatisfy(Self.ownedIDs.contains) else {
            Log.app.error("input method preferences refused: unsupported schema or unknown requested ID")
            throw InputMethodManagementError.systemFailure
        }
        var desired = Set(ids)
        var after: [[String: Any]] = []
        for entry in before {
            if let id = Self.ownedID(entry) {
                if desired.remove(id) != nil { after.append(entry) }
            } else {
                after.append(entry)
            }
        }
        for id in Self.ownedIDs where desired.contains(id) {
            var entry = ["Bundle ID": InputMethodManager.bundleID,
                         "InputSourceKind": id == InputMethodManager.bundleID ? "Keyboard Input Method" : "Input Mode"]
            if id != InputMethodManager.bundleID { entry["Input Mode"] = id }
            after.append(entry)
        }
        guard !(before as NSArray).isEqual(to: after) else { return true }
        Log.app.notice("input method preferences update ownIDs=\(ids.joined(separator: ",")) entriesBefore=\(before.count) entriesAfter=\(after.count)")
        guard write(after) else {
            let restored = write(before)
            Log.app.error("input method preferences write failed restored=\(restored)")
            invalidate()
            publish()
            throw InputMethodManagementError.systemFailure
        }
        invalidate()
        guard let verified = entries, (verified as NSArray).isEqual(to: after) else {
            let restored = write(before)
            Log.app.error("input method preferences readback mismatch restored=\(restored)")
            invalidate()
            publish()
            throw InputMethodManagementError.systemFailure
        }
        publish()
        return true
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
