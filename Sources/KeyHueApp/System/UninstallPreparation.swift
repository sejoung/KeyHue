import Carbon
import Foundation
import KeyHueCore
import ServiceManagement

/// ADR 0074: the steps of `scripts/uninstall.sh` that only this app's process can
/// take. Prints one line per step (names and statuses only) and returns whether
/// every step succeeded.
@MainActor
enum UninstallPreparation {
    static func run() -> Bool {
        var ok = true
        func report(_ step: String, _ success: Bool, _ detail: String = "") {
            print("\(success ? "ok" : "FAIL") \(step)\(detail.isEmpty ? "" : " \(detail)")")
            ok = ok && success
        }

        // Typing must not be left in a mode whose files are about to be deleted.
        if let current = InputSourceController.current()?.id, current.hasPrefix(InputMethodIntegration.bundleID) {
            let target = fallbackSourceID()
            let selected = target.map(InputSourceController.selectNative(sourceID:)) ?? false
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            report("leave KeyHue input mode", selected, "target=\(target ?? "none")")
        } else {
            report("leave KeyHue input mode", true, "not selected")
        }

        // Modes first, then the parent: a removed bundle must not leave dead list entries.
        let filter = [kTISPropertyBundleID as String: InputMethodIntegration.bundleID] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let enabled = sources.filter { boolProperty($0, kTISPropertyInputSourceIsEnabled) }
            .sorted { stringProperty($0, kTISPropertyInputSourceID) != InputMethodIntegration.bundleID
                && stringProperty($1, kTISPropertyInputSourceID) == InputMethodIntegration.bundleID }
        for source in enabled {
            let status = TISDisableInputSource(source)
            report("turn off input source", status == noErr, "\(stringProperty(source, kTISPropertyInputSourceID) ?? "?") status=\(status)")
        }
        if enabled.isEmpty { report("turn off input source", true, "none enabled") }

        if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
            report("remove login item", true, "not registered")
        } else {
            do {
                try SMAppService.mainApp.unregister()
                report("remove login item", true)
            } catch {
                report("remove login item", false, "\(error)")
            }
        }
        return ok
    }

    /// For `scripts/uninstall.sh`: enabled, requiresApproval, notRegistered or notFound.
    static var loginItemStatusName: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// ABC, or another enabled keyboard source that types ASCII.
    private static func fallbackSourceID() -> String? {
        let others = InputSourceController.enabledSources().filter { !$0.id.hasPrefix(InputMethodIntegration.bundleID) }
        if others.contains(where: { $0.id == InputMethodIntegration.abcID }) { return InputMethodIntegration.abcID }
        return others.first(where: \.isASCIICapable)?.id ?? others.first?.id
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return (Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? NSNumber)?.boolValue ?? false
    }
}
