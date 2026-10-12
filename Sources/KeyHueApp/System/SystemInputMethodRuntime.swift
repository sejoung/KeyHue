import AppKit
import Carbon
import KeyHueCore

@MainActor
final class SystemInputMethodRuntime: InputMethodRuntime {
    private let preferences: InputMethodSourcePreferences
    private let workerExecutable: URL?

    init(preferences: InputMethodSourcePreferences = .shared, workerExecutable: URL? = Bundle.main.executableURL) {
        self.preferences = preferences
        self.workerExecutable = workerExecutable
    }

    /// A fresh process sees registrations this process's TIS cache may miss.
    /// Test hosts are not KeyHue and read this process's TIS instead.
    private func snapshot() async -> InputSourceDiagnosticSnapshot? {
        guard WorkerCommand.runsWorkers(workerExecutable) else { return InputSourceController.diagnosticSnapshot() }
        let worker = workerExecutable
        return await ProcessRunner.inBackground { InputSourceController.freshSnapshot(workerExecutable: worker) }
    }

    var enabledIDs: [String] {
        if let configured = preferences.enabledIDs { return configured }
        return TISInputSource.keyHueSources(includeAllInstalled: true).filter(\.isEnabled).compactMap(\.id)
            .filter(InputMethodIntegration.ownedIDs.contains)
    }

    func isSelected() async -> Bool? {
        if preferences.isSupported, WorkerCommand.runsWorkers(workerExecutable) {
            guard let current = await snapshot()?.currentID else { return nil }
            return InputMethodIntegration.ownedIDs.contains(current)
        }
        guard let source = TISInputSource.current else { return nil }
        return source.bundleID == InputMethodIntegration.bundleID || source.id.map(InputMethodIntegration.ownedIDs.contains) == true
    }

    func catalog() async -> InputMethodCatalog {
        let snapshot = await snapshot()
        Log.app.notice("input method readiness: \(snapshot?.logDescription ?? "worker unavailable")")
        return InputMethodCatalog(isRegistered: snapshot?.sources.contains { $0.id == InputMethodIntegration.bundleID } == true,
                                  isReady: snapshot?.isReady == true)
    }

    func verify(_ bundle: URL) async throws {
        let path = bundle.path
        let status = await ProcessRunner.inBackground {
            ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                              arguments: ["--verify", "--deep", "--strict", path], timeout: 60)?.status
        }
        guard status == 0 else {
            Log.app.error("input method signature check failed status=\(status.map(String.init) ?? "unavailable")")
            throw InputMethodManagementError.invalidBundle
        }
    }

    func stop() async throws {
        try await requireInactive()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodIntegration.bundleID)
        for app in apps { app.terminate() }
        for _ in 0..<20 {
            if apps.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw InputMethodManagementError.stillRunning
    }

    /// The parent entry is turned off; mode requests are made too, though macOS 26 ignores
    /// them, so a later macOS that honors them leaves nothing behind.
    func disableOwnSources() {
        let sources = TISInputSource.keyHueSources(includeAllInstalled: true).filter(\.isEnabled)
            .sorted { $0.id != InputMethodIntegration.bundleID && $1.id == InputMethodIntegration.bundleID }
        for source in sources {
            Log.app.notice("input source \(source.id ?? "?") disabled status=\(TISDisableInputSource(source))")
        }
        preferences.invalidate()
    }

    func register(_ bundle: URL) throws {
        let result = TISRegisterInputSource(bundle as CFURL)
        Log.app.notice("input method registration status: \(result)")
        guard result == noErr else { throw InputMethodManagementError.systemFailure }
    }
}
