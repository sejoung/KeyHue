import Foundation

/// A macOS setting for all apps in the global domain (`defaults -g`). KeyHue reads
/// it fresh every time: the user changes it in System Settings while KeyHue runs.
struct GlobalPreference {
    let key: String
    /// Tests use a scratch domain.
    let domain: CFString

    /// nil when the key is missing (macOS uses its default) or not a number.
    var bool: Bool? {
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.boolValue
    }

    /// nil deletes the key, which restores macOS's default.
    func set(_ value: Bool?) {
        CFPreferencesSetValue(key as CFString, value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
