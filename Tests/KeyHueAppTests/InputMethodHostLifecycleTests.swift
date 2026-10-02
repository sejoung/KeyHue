import Carbon
import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// Explicitly opted-in local verification. CI/unit runs never mutate host sources.
@MainActor
@Suite("Opt-in actual input method lifecycle")
struct InputMethodHostLifecycleTests {
    /// Requires an installation whose two modes the user already added.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYHUE_TEST_HOST_UPDATE"] == "1"))
    func updateInstalledServiceThenRepeatedInstallIsANoop() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["KEYHUE_TEST_APP_PATH"])
        let app = URL(fileURLWithPath: root)
        let worker = app.appendingPathComponent("Contents/MacOS/KeyHue")
        let manager = InputMethodManager(appURL: app, runtime: SystemInputMethodRuntime(workerExecutable: worker))
        try #require(manager.status.isInstalled)
        try #require(try freshState(worker).isReady)
        let original = try #require(freshState(worker).currentID)
        try #require(!InputMethodSourcePreferences.ownedIDs.contains(original))
        let entries = allEntries()
        #expect(try await manager.install())
        #expect(!manager.status.needsUpdate)
        #expect(try freshState(worker).isReady)
        let modified = try manager.destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(try await manager.install())
        #expect(!manager.requiresRelaunch)
        #expect(try manager.destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect((allEntries() as NSArray).isEqual(to: entries))
        #expect(try freshState(worker).currentID == original)
    }

    /// Requires no installation and no KeyHue modes in System Settings.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KEYHUE_TEST_HOST_INPUT_METHOD"] == "1"))
    func installAndRemoveNeverChangeTheInputSourceList() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["KEYHUE_TEST_APP_PATH"])
        let app = URL(fileURLWithPath: root)
        let worker = app.appendingPathComponent("Contents/MacOS/KeyHue")
        let manager = InputMethodManager(appURL: app, runtime: SystemInputMethodRuntime(workerExecutable: worker))
        try #require(!manager.status.isInstalled)
        try #require(!manager.status.hasRegisteredSources)
        let original = try #require(freshState(worker).currentID)
        try #require(!InputMethodSourcePreferences.ownedIDs.contains(original))
        let entries = allEntries()
        do {
            for _ in 0..<2 {
                #expect(try await !manager.install())
                #expect(manager.status.isInstalled)
                #expect(try freshState(worker).sources.contains { $0.id == InputMethodManager.bundleID })
                #expect(try freshIDs(worker).isEmpty)
                #expect((allEntries() as NSArray).isEqual(to: entries))
                try await manager.uninstall()
                #expect(!FileManager.default.fileExists(atPath: manager.destination.path))
                #expect((allEntries() as NSArray).isEqual(to: entries))
            }
        } catch {
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

    private func allEntries() -> [[String: Any]] {
        _ = CFPreferencesAppSynchronize(InputMethodSourcePreferences.domain)
        return CFPreferencesCopyAppValue(InputMethodSourcePreferences.key, InputMethodSourcePreferences.domain) as? [[String: Any]] ?? []
    }
}
