import AppKit
import Carbon
import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// Explicitly opted-in local verification. CI/unit runs never mutate host sources.
@MainActor
@Suite("Opt-in actual input method lifecycle")
struct InputMethodHostLifecycleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYHUE_TEST_HOST_UPDATE"] == "1"))
    func updateInstalledServiceThenRepeatedEnableIsANoop() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["KEYHUE_TEST_APP_PATH"])
        let app = URL(fileURLWithPath: root)
        let worker = app.appendingPathComponent("Contents/MacOS/KeyHue")
        let manager = InputMethodManager(appURL: app, runtime: SystemInputMethodRuntime(workerExecutable: worker))
        try #require(manager.status.isInstalled)
        let original = try #require(freshState(worker).currentID)
        try #require(!InputMethodSourcePreferences.ownedIDs.contains(original))
        let others = otherEntries()
        #expect(try await manager.install())
        #expect(!manager.status.needsUpdate)
        #expect(try freshState(worker).isReady)
        let modified = try manager.destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try await manager.install())
        #expect(!manager.requiresRelaunch)
        #expect(try manager.destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect((otherEntries() as NSArray).isEqual(to: others))
        #expect(try freshState(worker).currentID == original)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYHUE_TEST_HOST_INPUT_METHOD"] == "1"))
    func installRemoveReinstallPreservesOtherSources() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["KEYHUE_TEST_APP_PATH"])
        let app = URL(fileURLWithPath: root)
        let worker = app.appendingPathComponent("Contents/MacOS/KeyHue")
        let manager = InputMethodManager(appURL: app, runtime: SystemInputMethodRuntime(workerExecutable: worker))
        _ = NSApplication.shared
        let monitor = InputSourceMonitor()
        monitor.start { source in print("host source notification: \(source?.id ?? "none")") }
        defer { monitor.stop() }
        #expect(InputMethodSourcePreferences.shared.isSupported)
        try #require(!manager.status.isInstalled)
        let original = try #require(InputSourceController.current()?.id)
        try #require(!InputMethodSourcePreferences.ownedIDs.contains(original))
        let othersBefore = otherEntries()
        do {
            // Also repairs the exact orphan configuration from the reported bug.
            try await manager.uninstall()
            #expect(!manager.status.hasRegisteredSources)
            for _ in 0..<2 {
                #expect(try await manager.install())
                #expect(Set(try freshIDs(worker)) == Set([InputMethodIntegration.hangulID, InputMethodIntegration.latinID]))
                #expect(try freshState(worker).isReady)
                InputMethodSourcePreferences.shared.invalidate()
                #expect(InputMethodIntegration.isAvailable(in: InputSourceController.enabledSources()))
                if ProcessInfo.processInfo.environment["KEYHUE_TEST_HOST_SELECTION"] == "1" {
                    // Run only in a quiet test session: normal focus/document
                    // restoration can overwrite a programmatic selection.
                    for id in [InputMethodIntegration.hangulID, InputMethodIntegration.latinID] {
                        #expect(InputSourceController.selectFresh(sourceID: id, workerExecutable: worker))
                        #expect(try freshState(worker).currentID == id)
                    }
                    #expect(InputSourceController.selectFresh(sourceID: original, workerExecutable: worker))
                }
                #expect(try freshState(worker).currentID == original)
                try await manager.uninstall()
                #expect(!FileManager.default.fileExists(atPath: manager.destination.path))
                #expect(!manager.status.hasRegisteredSources)
                #expect(try freshIDs(worker).isEmpty)
                #expect((otherEntries() as NSArray).isEqual(to: othersBefore))
            }
        } catch {
            _ = InputSourceController.selectFresh(sourceID: original, workerExecutable: worker)
            try? await manager.uninstall()
            throw error
        }
        #expect(try freshState(worker).currentID == original)
    }

    private func freshIDs(_ worker: URL) throws -> [String] {
        try freshState(worker).enabledIDs
    }

    private func freshState(_ worker: URL) throws -> InputSourceDiagnosticSnapshot {
        let task = Process()
        let output = Pipe()
        task.executableURL = worker
        task.arguments = ["--keyhue-input-source-status"]
        task.standardOutput = output
        try task.run()
        task.waitUntilExit()
        try #require(task.terminationStatus == 0)
        return try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: output.fileHandleForReading.readDataToEndOfFile())
    }

    private func otherEntries() -> [[String: Any]] {
        _ = CFPreferencesAppSynchronize(InputMethodSourcePreferences.domain)
        let entries = CFPreferencesCopyAppValue(InputMethodSourcePreferences.key, InputMethodSourcePreferences.domain) as? [[String: Any]] ?? []
        return entries.filter { $0["Bundle ID"] as? String != InputMethodManager.bundleID }
    }
}
