import AppKit
import Carbon

/// The process holding secure event input. While any process holds it, macOS does not
/// let a third-party input method such as KeyHue's modes stay selected and puts ABC
/// back, even in other apps (2026-11-18 13:04–13:12: Chrome held it from the background).
struct SecureInputHolder {
    let pid: pid_t
    let bundleID: String?
    /// The app's name as the user knows it, or nil for a process that is not an app.
    let name: String?

    /// nil when secure input is off or no holder is reported.
    static func current() -> SecureInputHolder? {
        guard IsSecureEventInputEnabled(),
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return SecureInputHolder(pid: pid, bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    /// "pid 1214 com.google.Chrome", or nil when no holder is reported.
    static func describe() -> String? {
        current()?.description
    }

    var description: String { "pid \(pid) \(bundleID ?? "unknown")" }
}
