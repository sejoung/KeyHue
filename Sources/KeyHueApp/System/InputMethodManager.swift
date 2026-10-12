import Foundation
import KeyHueCore

struct InputMethodInstallationStatus: Equatable {
    var hasPayload = false
    var isInstalled = false
    var needsUpdate = false
    var hasRegisteredSources = false
}

enum InputMethodManagementError: Error, LocalizedError {
    case invalidBundle, payloadMissing, activeSource, statusUnavailable, stillRunning, systemFailure, inputSourcesInUse
    var errorDescription: String? {
        switch self {
        case .invalidBundle: return L("The input method bundle is invalid or the install location belongs to another app.")
        case .payloadMissing: return L("This copy of KeyHue does not include its input method. Install the packaged KeyHue app.")
        case .activeSource: return L("Finish composition and switch to a system input source before installing or removing the input method.")
        case .statusUnavailable: return L("KeyHue could not check the current input source. Try again in a moment.")
        case .stillRunning: return L("The input method did not quit. Log out and back in, then try again.")
        case .systemFailure: return L("macOS could not complete the input method operation. The previous installation was kept where possible.")
        case .inputSourcesInUse: return L("KeyHue can't remove its input modes for you. Remove KeyHue Korean and English yourself in System Settings → Keyboard → Text Input → Edit, then remove the input method again.")
        }
    }
}

/// What a fresh process sees of the input method in the TIS catalog.
struct InputMethodCatalog: Equatable, Sendable {
    /// The parent entry is registered.
    var isRegistered = false
    /// The parent and both modes are enabled and selectable.
    var isReady = false
}

/// OS calls are injected so file transactions can be tested without registering
/// a service or stopping the real user's input method process.
/// KeyHue never adds or removes input sources; the user does that in System Settings.
/// The slow calls (a worker process, `codesign`) are async and run off the main thread.
@MainActor
protocol InputMethodRuntime: AnyObject {
    /// Whether a KeyHue input source is current. nil when it could not be read.
    func isSelected() async -> Bool?
    var enabledIDs: [String] { get }
    func catalog() async -> InputMethodCatalog
    func verify(_ bundle: URL) async throws
    func stop() async throws
    func register(_ bundle: URL) throws
}

extension InputMethodRuntime {
    /// Files are replaced only while no KeyHue mode is in use. A state that cannot
    /// be read blocks too, with its own message.
    func requireInactive() async throws {
        switch await isSelected() {
        case false?: return
        case true?: throw InputMethodManagementError.activeSource
        case nil: throw InputMethodManagementError.statusUnavailable
        }
    }
}

@MainActor
final class InputMethodManager {
    static let appName = InputMethodIntegration.executableName + ".app"
    static let embeddedPath = "Contents/Helpers/" + appName
    let payload: URL
    let destination: URL
    private let runtime: InputMethodRuntime
    private let files = FileManager.default
    private let bundles: InputMethodBundleInspector
    private var operating = false
    private(set) var requiresRelaunch = false

    init(appURL: URL = Bundle.main.bundleURL,
         installDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true),
         runtime: InputMethodRuntime = SystemInputMethodRuntime()) {
        payload = appURL.appendingPathComponent(Self.embeddedPath, isDirectory: true)
        destination = installDirectory.appendingPathComponent(Self.appName, isDirectory: true)
        bundles = InputMethodBundleInspector(payload: payload, destination: destination)
        self.runtime = runtime
    }

    var status: InputMethodInstallationStatus {
        var status = bundles.installation()
        status.hasRegisteredSources = hasUserModes
        return status
    }

    /// Modes the user added. A non-selectable parent entry is not shown in System Settings.
    private var hasUserModes: Bool {
        !InputMethodIntegration.modeIDs.isDisjoint(with: runtime.enabledIDs)
    }

    /// False means installation succeeded but the user has not added both modes yet.
    func install() async throws -> Bool {
        guard !operating else { throw InputMethodManagementError.systemFailure }
        operating = true
        requiresRelaunch = false
        let operation = UUID().uuidString
        Log.app.notice("input method install begin operation=\(operation) destination=\(destination.path)")
        defer {
            operating = false; bundles.invalidate()
            Log.app.notice("input method install end operation=\(operation) installed=\(status.isInstalled) configured=\(runtime.enabledIDs.joined(separator: ",")) relaunch=\(requiresRelaunch)")
        }
        guard files.fileExists(atPath: payload.path) else { throw InputMethodManagementError.payloadMissing }
        try bundles.validate(payload)
        try await runtime.verify(payload)
        try requireSeparateLocations()
        if bundles.exists(destination) { try bundles.validate(destination) }
        try await runtime.requireInactive()
        if status.isInstalled && !status.needsUpdate {
            // A copy installed before ADR 0085 may still carry the download's quarantine.
            Self.clearQuarantine(destination)
            // Registering an unchanged bundle again can repeat macOS's
            // new-input-source notification. Only restore a missing catalog entry.
            var catalog = await runtime.catalog()
            if !catalog.isRegistered {
                requiresRelaunch = true
                try runtime.register(destination)
                catalog = await runtime.catalog()
            }
            Log.app.notice("input method install unchanged operation=\(operation)")
            return catalog.isReady
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Temporary and backup apps must stay outside macOS's watched input-method folder.
        let staging = files.temporaryDirectory.appendingPathComponent("KeyHueInputMethodInstall-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        var preserveStaging = false
        defer { if !preserveStaging { try? files.removeItem(at: staging) } }
        let candidate = staging.appendingPathComponent(Self.appName)
        let previous = staging.appendingPathComponent("previous.app")
        try files.copyItem(at: payload, to: candidate)
        Self.clearQuarantine(candidate)
        try await runtime.verify(candidate)
        try await runtime.requireInactive()
        try await runtime.stop()
        try await runtime.requireInactive()
        var movedOld = false
        var movedNew = false
        do {
            if bundles.exists(destination) {
                try files.moveItem(at: destination, to: previous)
                movedOld = true
            }
            try files.moveItem(at: candidate, to: destination)
            movedNew = true
            try await runtime.verify(destination)
            requiresRelaunch = true
            try runtime.register(destination)
            return await runtime.catalog().isReady
        } catch {
            Log.app.error("input method install rollback operation=\(operation) error=\(error)")
            if movedNew { try? files.removeItem(at: destination) }
            if movedOld {
                try? files.moveItem(at: previous, to: destination)
                try? runtime.register(destination)
            }
            preserveStaging = bundles.exists(previous)
            throw error
        }
    }

    func uninstall() async throws {
        guard !operating else { throw InputMethodManagementError.systemFailure }
        operating = true
        requiresRelaunch = false
        let operation = UUID().uuidString
        Log.app.notice("input method uninstall begin operation=\(operation) destination=\(destination.path)")
        defer {
            operating = false; bundles.invalidate()
            Log.app.notice("input method uninstall end operation=\(operation) installed=\(status.isInstalled) configured=\(runtime.enabledIDs.joined(separator: ","))")
        }
        try requireSeparateLocations()
        try await runtime.requireInactive()
        // Deleting files under modes the user still has would leave dead entries
        // in their input source list. Only the user can remove those modes.
        guard !hasUserModes else { throw InputMethodManagementError.inputSourcesInUse }
        guard bundles.exists(destination) else { return }
        try bundles.validate(destination)
        try await runtime.verify(destination)
        try await runtime.requireInactive()
        try await runtime.stop()
        try await runtime.requireInactive()
        guard !hasUserModes else { throw InputMethodManagementError.inputSourcesInUse }
        // Only the exact, verified service bundle is removed; user settings stay.
        try files.removeItem(at: destination)
        requiresRelaunch = true
    }

    /// The packaged payload must never be the install location, contain it, or be inside it.
    /// Otherwise an update writes into the signed app or a removal deletes its payload.
    private func requireSeparateLocations() throws {
        let source = payload.resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard source != target, !source.hasPrefix(target + "/"), !target.hasPrefix(source + "/") else {
            throw InputMethodManagementError.invalidBundle
        }
    }

    /// ADR 0085: a downloaded KeyHue.app carries the download's quarantine on every file,
    /// and copying keeps it. The user opened KeyHue itself; macOS launches the copied input
    /// method on its own and blocked it as an unverified app. The copy is still checked
    /// with `codesign --verify --deep --strict` after this.
    @discardableResult
    static func clearQuarantine(_ bundle: URL) -> Int {
        let name = "com.apple.quarantine"
        var paths = [bundle.path]
        if let items = FileManager.default.enumerator(atPath: bundle.path) {
            for case let item as String in items { paths.append(bundle.appendingPathComponent(item).path) }
        }
        let cleared = paths.filter { removexattr($0, name, XATTR_NOFOLLOW) == 0 }.count
        if cleared > 0 { Log.app.notice("input method quarantine cleared files=\(cleared)") }
        return cleared
    }
}
