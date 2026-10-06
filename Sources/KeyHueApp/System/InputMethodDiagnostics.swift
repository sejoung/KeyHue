import Foundation
import KeyHueCore

/// Static select capability does not mean a mode is usable: its parent must
/// also be enabled. Keep this evidence separate from configured preferences.
struct InputMethodSourceState: Codable, Equatable {
    var id: String
    var enabled: Bool
    var selectable: Bool
    var enableCapable: Bool
}

struct InputSourceDiagnosticSnapshot: Codable {
    var enabledIDs: [String]
    var currentID: String?
    var sources: [InputMethodSourceState] = []
    var configuredIDs: [String]? = nil

    var isReady: Bool {
        let parent = sources.filter { $0.id == InputMethodIntegration.bundleID }
        guard parent.count == 1, parent[0].enabled else { return false }
        return [InputMethodIntegration.hangulID, InputMethodIntegration.latinID].allSatisfy { id in
            let modes = sources.filter { $0.id == id }
            return modes.count == 1 && modes[0].enabled && modes[0].selectable && enabledIDs.contains(id)
        }
    }

    var logDescription: String {
        let catalog = sources.sorted { $0.id < $1.id }.map {
            "\($0.id)[enabled=\($0.enabled),selectable=\($0.selectable),enableCapable=\($0.enableCapable)]"
        }.joined(separator: ";")
        return "ready=\(isReady) current=\(currentID ?? "none") configured=\(configuredIDs?.joined(separator: ",") ?? "unsupported") native=\(enabledIDs.joined(separator: ",")) catalog=\(catalog)"
    }
}
