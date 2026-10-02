import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
private final class FakeInputMethodRuntime: InputMethodRuntime {
    var isSelected = false
    var enabledIDs: [String] = []
    var isReady: Bool { modesReady && Set(enabledIDs) == Set([InputMethodIntegration.hangulID, InputMethodIntegration.latinID]) }
    var isRegistered = true
    var events: [String] = []
    var failRegistration = false
    var failVerificationAt: Int?
    var verificationCount = 0
    var verifiedURLs: [URL] = []
    var failStop = false
    var reselectOnStop = false
    var modesReady = true
    var failDisable = false
    var keepModesAfterDisable = false
    var failEnable = false
    var suspendStop = false
    var stopContinuation: CheckedContinuation<Void, Never>?
    func verify(_ bundle: URL) throws {
        verificationCount += 1
        verifiedURLs.append(bundle)
        events.append("verify")
        if verificationCount == failVerificationAt { throw InputMethodManagementError.invalidBundle }
    }
    func stop() async throws {
        events.append("stop")
        if suspendStop { await withCheckedContinuation { stopContinuation = $0 } }
        if failStop { throw InputMethodManagementError.stillRunning }
        if reselectOnStop { isSelected = true }
    }
    func register(_ bundle: URL) throws {
        events.append("register")
        if failRegistration { throw InputMethodManagementError.systemFailure }
    }
    func enable() throws -> Bool {
        events.append("enable")
        if modesReady { enabledIDs = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID] }
        if failEnable { throw InputMethodManagementError.systemFailure }
        return modesReady
    }
    func disable() throws {
        events.append("disable")
        if failDisable { throw InputMethodManagementError.systemFailure }
        if !keepModesAfterDisable { enabledIDs = [] }
    }
    func restoreEnabled(_ ids: [String]) { events.append("restore"); enabledIDs = ids }
}

@MainActor
private final class InstallationFixture {
    let root: URL
    let runtime = FakeInputMethodRuntime()
    let manager: InputMethodManager
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueInstallTests-" + UUID().uuidString, isDirectory: true)
        manager = InputMethodManager(appURL: root.appendingPathComponent("KeyHue.app"), installDirectory: root.appendingPathComponent("Input Methods"), runtime: runtime)
        try makeBundle(manager.payload, version: "2.0.0")
    }
    func makeBundle(_ url: URL, version: String, bundleID: String = InputMethodManager.bundleID) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/KeyHueInputMethodSpike"))
        let metadata: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "KeyHueInputMethodSpike", "LSBackgroundOnly": true,
                                     "InputMethodServerControllerClass": "KeyHueSpikeInputController", "InputMethodConnectionName": "KeyHueInputMethodSpike_Connection",
                                     "CFBundleShortVersionString": version, "CFBundleVersion": "42"]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite("Bundled input method management")
struct InputMethodManagerTests {
    @Test func missingCatalogOnAnUnchangedInstallationRegistersOnceBeforeActivation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.enabledIDs = []
        f.runtime.isRegistered = false
        f.runtime.events = []
        #expect(try await f.manager.install())
        #expect(f.runtime.events == ["verify", "register", "enable"])
        #expect(f.manager.requiresRelaunch)
    }

    @Test func concurrentInstallAndRemoveCannotEnterTheFileTransaction() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.suspendStop = true
        let install = Task { try await f.manager.install() }
        for _ in 0..<100 where f.runtime.stopContinuation == nil { await Task.yield() }
        let continuation = try #require(f.runtime.stopContinuation)
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        continuation.resume()
        #expect(try await install.value)
        #expect(f.runtime.events.filter { $0 == "register" }.count == 1)
    }

    @Test func orphanCleanupMustVerifyDisableEvenWhenFilesAreAlreadyMissing() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.enabledIDs = [InputMethodIntegration.hangulID]
        f.runtime.keepModesAfterDisable = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.hasRegisteredSources)
        #expect(!f.manager.requiresRelaunch)
    }

    @Test func removalRefusesReselectionDuringTerminationAndKeepsFilesAndModes() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.reselectOnStop = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
        #expect(f.runtime.enabledIDs.count == 2)
    }

    @Test func installsSignedPayloadAndActivatesBothModesWithoutTouchingHostSources() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        #expect(f.manager.status.hasPayload)
        #expect(!f.manager.status.isInstalled)
        #expect(try await f.manager.install())
        #expect(f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
        #expect(f.runtime.events == ["verify", "verify", "stop", "verify", "register", "enable"])
        #expect(f.runtime.enabledIDs == [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    }

    @Test func updatesExistingLegacyServiceInSameLocation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        #expect(f.manager.status.needsUpdate)
        #expect(try await f.manager.install())
        #expect(!f.manager.status.needsUpdate)
    }

    @Test func alreadyReadyPayloadDoesNotRegisterEnableCopyStopOrRelaunchAgain() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.events = []
        #expect(try await f.manager.install())
        #expect(f.runtime.events == ["verify"])
        #expect(!f.manager.requiresRelaunch)
    }

    @Test func currentInstallActivationFailureRestoresPreviousEnabledModes() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.enabledIDs = [InputMethodIntegration.hangulID]
        f.runtime.failEnable = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(f.manager.status.isInstalled)
        #expect(f.runtime.enabledIDs == [InputMethodIntegration.hangulID])
    }

    @Test func missingOrUntrustedPayloadNeverCreatesAnInstallation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.failVerificationAt = 1
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(!FileManager.default.fileExists(atPath: f.manager.destination.path))
        #expect(!f.runtime.events.contains("stop"))
        try FileManager.default.removeItem(at: f.manager.payload)
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(!f.manager.status.hasPayload)
    }

    @Test func sameVersionChangedExecutableOffersUpdate() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        let executable = f.manager.payload.appendingPathComponent("Contents/MacOS/KeyHueInputMethodSpike")
        try Data("changed".utf8).write(to: executable)
        #expect(f.manager.status.needsUpdate)
    }

    @Test func failedRegistrationRestoresPreviousFilesAndModePreferences() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        let original = try Data(contentsOf: f.manager.destination.appendingPathComponent("Contents/Info.plist"))
        f.runtime.enabledIDs = [InputMethodIntegration.hangulID]
        f.runtime.failRegistration = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(try Data(contentsOf: f.manager.destination.appendingPathComponent("Contents/Info.plist")) == original)
        #expect(f.runtime.enabledIDs == [InputMethodIntegration.hangulID])
    }

    @Test func failedFinalVerificationRemovesFirstInstallAndLeavesPayloadIntact() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.failVerificationAt = 3
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(!FileManager.default.fileExists(atPath: f.manager.destination.path))
        #expect(f.manager.status.hasPayload)
    }

    @Test func selectedOrReselectedInputMethodIsNeverReplaced() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.isSelected = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(!f.runtime.events.contains("stop"))
        f.runtime.isSelected = false
        f.runtime.reselectOnStop = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(!FileManager.default.fileExists(atPath: f.manager.destination.path))
    }

    @Test func foreignBundleAndSymlinkAreNotOverwrittenOrRemoved() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        let foreign = f.root.appendingPathComponent("Foreign.app")
        try f.makeBundle(foreign, version: "1.0.0", bundleID: "another.app")
        try FileManager.default.createDirectory(at: f.manager.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.manager.destination, withDestinationURL: foreign)
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(f.runtime.events.isEmpty || f.runtime.events == ["verify"])
        try FileManager.default.removeItem(at: f.manager.destination)
        try FileManager.default.moveItem(at: foreign, to: f.manager.destination)
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(FileManager.default.fileExists(atPath: f.manager.destination.path))
    }

    @Test func registrationWithoutAvailableModesKeepsInstallationAndLaterActivationDoesNotCopyAgain() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.modesReady = false
        #expect(try await !f.manager.install())
        #expect(f.manager.status.isInstalled)
        #expect(f.runtime.enabledIDs.isEmpty)
        f.runtime.modesReady = true
        f.runtime.events = []
        #expect(try await f.manager.install())
        #expect(f.runtime.events == ["verify", "enable"])
    }

    @Test func removalThenReinstallUsesPackagedPayloadAndFreshActivation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        #expect(try await f.manager.install())
        try await f.manager.uninstall()
        #expect(f.runtime.enabledIDs.isEmpty)
        #expect(try await f.manager.install())
        #expect(f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
        #expect(f.runtime.enabledIDs.count == 2)
    }

    @Test func missingFilesDoNotPreventCleaningConfiguredSourceRemnants() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.enabledIDs = [InputMethodIntegration.hangulID]
        #expect(!f.manager.status.isInstalled)
        #expect(f.manager.status.hasRegisteredSources)
        try await f.manager.uninstall()
        #expect(f.runtime.events == ["disable"])
        #expect(!f.manager.status.hasRegisteredSources)
    }

    @Test func successfulDisableWithoutRemovingModesDoesNotDeleteFiles() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        #expect(try await f.manager.install())
        f.runtime.keepModesAfterDisable = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
        #expect(f.runtime.enabledIDs.count == 2)
    }

    @Test func stagedBundlesStayOutsideTheWatchedInputMethodsDirectory() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        #expect(try await f.manager.install())
        let staged = f.runtime.verifiedURLs[1]
        #expect(!staged.path.hasPrefix(f.manager.destination.deletingLastPathComponent().path + "/"))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func uninstallDisablesOnlyManagedSourcesAndPreservesPackagedApp() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.events = []
        try await f.manager.uninstall()
        #expect(f.runtime.events == ["verify", "stop", "disable"])
        #expect(!f.manager.status.isInstalled)
        #expect(f.manager.status.hasPayload)
    }

    @Test func failedTerminationAndDisableKeepInstalledService() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.failStop = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
        f.runtime.failStop = false
        f.runtime.failDisable = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
        #expect(f.runtime.enabledIDs.count == 2)
    }
}
