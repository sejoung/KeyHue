import AppKit
import Carbon
import Foundation
import KeyHueCore

struct InputMethodInstallationStatus: Equatable {
    var hasPayload = false
    var isInstalled = false
    var needsUpdate = false
    var hasRegisteredSources = false
}

enum InputMethodManagementError: Error, LocalizedError {
    case invalidBundle, payloadMissing, activeSource, stillRunning, systemFailure
    var errorDescription: String? {
        switch self {
        case .invalidBundle: return L("The input method bundle is invalid or the install location belongs to another app.")
        case .payloadMissing: return L("This copy of KeyHue does not include its input method. Install the packaged KeyHue app.")
        case .activeSource: return L("Finish composition and switch to a system input source before installing or removing the input method.")
        case .stillRunning: return L("The input method did not quit. Log out and back in, then try again.")
        case .systemFailure: return L("macOS could not complete the input method operation. The previous installation was kept where possible.")
        }
    }
}

/// OS mutations are injected so file transactions can be tested without changing
/// the real user's input sources or stopping their input method process.
@MainActor
protocol InputMethodRuntime: AnyObject {
    var isSelected: Bool { get }
    var enabledIDs: [String] { get }
    func verify(_ bundle: URL) throws
    func stop() async throws
    func register(_ bundle: URL) throws
    func enable() throws -> Bool
    func disable() throws
    func restoreEnabled(_ ids: [String])
}

@MainActor
final class InputMethodManager {
    static let bundleID = "io.github.sejoung.keyhue.inputmethod.spike"
    static let appName = "KeyHueInputMethodSpike.app"
    static let embeddedPath = "Contents/Helpers/" + appName
    let payload: URL
    let destination: URL
    private let runtime: InputMethodRuntime
    private let files = FileManager.default
    private var operating = false
    private struct FileState: Equatable {
        var modified: Date?
        var size: Int?
        var isLink: Bool?
    }
    private var cachedFileState: [FileState] = []
    private var cachedStatus: InputMethodInstallationStatus?

    init(appURL: URL = Bundle.main.bundleURL,
         installDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true),
         runtime: InputMethodRuntime = SystemInputMethodRuntime()) {
        payload = appURL.appendingPathComponent(Self.embeddedPath, isDirectory: true)
        destination = installDirectory.appendingPathComponent(Self.appName, isDirectory: true)
        self.runtime = runtime
    }

    var status: InputMethodInstallationStatus {
        // Menus refresh on every source change. Only read binaries if files changed.
        let watched = ["", "Contents/Info.plist", "Contents/MacOS/KeyHueInputMethodSpike", "Contents/_CodeSignature/CodeResources"]
        let fileState = [payload, destination].flatMap { bundle in
            watched.map { path in
                let values = try? bundle.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
                return FileState(modified: values?.contentModificationDate, size: values?.fileSize, isLink: values?.isSymbolicLink)
            }
        }
        if fileState == cachedFileState, var cachedStatus {
            cachedStatus.hasRegisteredSources = !runtime.enabledIDs.isEmpty
            return cachedStatus
        }
        let packaged = isOwnedBundle(payload)
        let installed = isOwnedBundle(destination)
        let versionKeys = ["CFBundleShortVersionString", "CFBundleVersion"]
        let versionsMatch = versionKeys.allSatisfy { info(payload)?[$0] as? String == info(destination)?[$0] as? String }
        // Same-version development rebuilds must also offer an update.
        let contentMatches = ["Contents/MacOS/KeyHueInputMethodSpike", "Contents/_CodeSignature/CodeResources"].allSatisfy {
            (try? Data(contentsOf: payload.appendingPathComponent($0))) == (try? Data(contentsOf: destination.appendingPathComponent($0)))
        }
        let result = InputMethodInstallationStatus(hasPayload: packaged, isInstalled: installed, needsUpdate: packaged && installed && !(versionsMatch && contentMatches), hasRegisteredSources: !runtime.enabledIDs.isEmpty)
        cachedFileState = fileState
        cachedStatus = result
        return result
    }

    /// False means installation succeeded but both modes are not yet enabled.
    func install() async throws -> Bool {
        guard !operating else { throw InputMethodManagementError.systemFailure }
        operating = true
        defer { operating = false; cachedStatus = nil }
        guard files.fileExists(atPath: payload.path) else { throw InputMethodManagementError.payloadMissing }
        try validate(payload)
        try runtime.verify(payload)
        guard payload.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath(),
              !payload.path.hasPrefix(destination.path + "/") else { throw InputMethodManagementError.invalidBundle }
        if exists(destination) { try validate(destination) }
        try requireInactive()
        if status.isInstalled && !status.needsUpdate {
            let enabledBefore = runtime.enabledIDs
            do {
                try runtime.register(destination)
                return try runtime.enable()
            } catch {
                try? runtime.disable()
                runtime.restoreEnabled(enabledBefore)
                throw error
            }
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
        try runtime.verify(candidate)
        try requireInactive()
        try await runtime.stop()
        try requireInactive()
        let enabledBefore = runtime.enabledIDs
        var movedOld = false
        var movedNew = false
        do {
            if exists(destination) {
                try files.moveItem(at: destination, to: previous)
                movedOld = true
            }
            try files.moveItem(at: candidate, to: destination)
            movedNew = true
            try runtime.verify(destination)
            try runtime.register(destination)
            return try runtime.enable()
        } catch {
            // Disable only newly enabled modes before undoing a first installation.
            try? runtime.disable()
            if movedNew { try? files.removeItem(at: destination) }
            if movedOld {
                try? files.moveItem(at: previous, to: destination)
                try? runtime.register(destination)
            }
            preserveStaging = exists(previous)
            if isOwnedBundle(destination) { runtime.restoreEnabled(enabledBefore) }
            throw error
        }
    }

    func uninstall() async throws {
        guard !operating else { throw InputMethodManagementError.systemFailure }
        operating = true
        defer { operating = false; cachedStatus = nil }
        try requireInactive()
        guard exists(destination) else {
            // A prior removal may have left a configured mode after deleting files.
            try runtime.disable()
            return
        }
        try validate(destination)
        try runtime.verify(destination)
        try requireInactive()
        try await runtime.stop()
        try requireInactive()
        let enabledBefore = runtime.enabledIDs
        do {
            try runtime.disable()
            guard runtime.enabledIDs.isEmpty else { throw InputMethodManagementError.systemFailure }
            try requireInactive()
            // Only the exact, verified service bundle is removed; user settings stay.
            try files.removeItem(at: destination)
        } catch {
            runtime.restoreEnabled(enabledBefore)
            throw error
        }
    }

    private func requireInactive() throws {
        if runtime.isSelected { throw InputMethodManagementError.activeSource }
    }

    private func exists(_ url: URL) -> Bool {
        files.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func info(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func isOwnedBundle(_ url: URL) -> Bool {
        guard files.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/KeyHueInputMethodSpike").path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let metadata = info(url) else { return false }
        return metadata["CFBundleIdentifier"] as? String == Self.bundleID
            && metadata["CFBundleExecutable"] as? String == "KeyHueInputMethodSpike"
            && metadata["LSBackgroundOnly"] as? Bool == true
            && metadata["InputMethodServerControllerClass"] as? String == "KeyHueSpikeInputController"
            && metadata["InputMethodConnectionName"] as? String == "KeyHueInputMethodSpike_Connection"
    }

    private func validate(_ url: URL) throws {
        guard isOwnedBundle(url) else { throw InputMethodManagementError.invalidBundle }
    }
}

@MainActor
final class SystemInputMethodRuntime: InputMethodRuntime {
    private let ids = [InputMethodManager.bundleID, InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
    private let preferences: InputMethodSourcePreferences
    private let workerExecutable: URL?
    init(preferences: InputMethodSourcePreferences = .shared, workerExecutable: URL? = Bundle.main.executableURL) {
        self.preferences = preferences
        self.workerExecutable = workerExecutable
    }
    private func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
    private var sources: [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: InputMethodManager.bundleID] as CFDictionary
        return TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
    }
    var enabledIDs: [String] {
        if let configured = preferences.enabledIDs { return configured }
        return sources.compactMap { source in
            guard (property(source, kTISPropertyInputSourceIsEnabled) as NSNumber?)?.boolValue == true else { return nil }
            let id: String? = property(source, kTISPropertyInputSourceID)
            return id.flatMap { ids.contains($0) ? $0 : nil }
        }
    }
    var isSelected: Bool {
        if preferences.isSupported, workerExecutable?.lastPathComponent == "KeyHue" {
            guard let snapshot = InputSourceController.freshSnapshot(workerExecutable: workerExecutable), let current = snapshot.currentID else { return true }
            return ids.contains(current)
        }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return true }
        let id: String? = property(source, kTISPropertyInputSourceID)
        let bundle: String? = property(source, kTISPropertyBundleID)
        return bundle == InputMethodManager.bundleID || id.map(ids.contains) == true
    }
    func verify(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InputMethodManagementError.invalidBundle }
    }
    func stop() async throws {
        guard !isSelected else { throw InputMethodManagementError.activeSource }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodManager.bundleID)
        for app in apps { app.terminate() }
        for _ in 0..<20 {
            if apps.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw InputMethodManagementError.stillRunning
    }
    func register(_ bundle: URL) throws {
        let result = TISRegisterInputSource(bundle as CFURL)
        Log.app.notice("input method registration status: \(result)")
        guard result == noErr else { throw InputMethodManagementError.systemFailure }
    }
    func enable() throws -> Bool {
        preferences.invalidate()
        let ready = try InputMethodActivation.enable(
            ids: ids, requiredIDs: Array(ids.dropFirst()), sources: { self.sources },
            id: { self.property($0, kTISPropertyInputSourceID) as String? },
            isEnabled: { (self.property($0, kTISPropertyInputSourceIsEnabled) as NSNumber?)?.boolValue == true },
            activate: { source in
                let result = TISEnableInputSource(source)
                let id: String = self.property(source, kTISPropertyInputSourceID) ?? "unknown"
                Log.app.notice("input method activation \(id): status=\(result)")
                guard result == noErr else { throw InputMethodManagementError.systemFailure }
            })
        let modes = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]
        if preferences.isSupported, !modes.allSatisfy(enabledIDs.contains) {
            try preferences.setEnabled(ids)
        }
        let available = preferences.isSupported
            ? modes.allSatisfy(enabledIDs.contains) && modes.allSatisfy { wanted in sources.contains { self.property($0, kTISPropertyInputSourceID) as String? == wanted } }
            : InputMethodIntegration.isAvailable(in: InputSourceController.enabledSources())
        let verifiedAvailable = available && (workerExecutable?.lastPathComponent != "KeyHue"
            || InputSourceController.freshSnapshot(workerExecutable: workerExecutable).map { snapshot in modes.allSatisfy(snapshot.enabledIDs.contains) } == true)
        Log.app.notice("input method activation catalogReady=\(ready), modesReady=\(available), enabled=\(self.enabledIDs.joined(separator: ","))")
        return verifiedAvailable
    }
    func disable() throws {
        preferences.invalidate()
        for id in ids.reversed() {
            for source in sources where property(source, kTISPropertyInputSourceID) as String? == id {
                let result = TISDisableInputSource(source)
                Log.app.notice("input method deactivation \(id): status=\(result)")
                guard result == noErr else { throw InputMethodManagementError.systemFailure }
            }
        }
        try preferences.setEnabled([])
        guard enabledIDs.isEmpty else { throw InputMethodManagementError.systemFailure }
        Log.app.notice("input method source configuration removed")
    }
    func restoreEnabled(_ previous: [String]) {
        for id in ids where previous.contains(id) {
            for source in sources where property(source, kTISPropertyInputSourceID) as String? == id {
                _ = TISEnableInputSource(source)
            }
        }
        _ = try? preferences.setEnabled(previous)
    }
}

/// Registration/activation can change the catalog. Never reuse source handles
/// captured before enabling the parent, and verify properties after API success.
@MainActor
enum InputMethodActivation {
    static func enable<Source>(ids: [String], requiredIDs: [String]? = nil, sources: () -> [Source],
                               id: (Source) -> String?, isEnabled: (Source) -> Bool,
                               activate: (Source) throws -> Void) throws -> Bool {
        let required = requiredIDs ?? ids
        for wanted in ids {
            guard let source = sources().first(where: { id($0) == wanted }) else {
                if required.contains(wanted) { return false }
                continue
            }
            if !isEnabled(source) { try activate(source) }
        }
        let enabled = Set(sources().filter(isEnabled).compactMap(id))
        return required.allSatisfy(enabled.contains)
    }
}
