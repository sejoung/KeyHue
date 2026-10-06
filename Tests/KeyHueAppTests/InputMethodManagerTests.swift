import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
private final class FakeInputMethodRuntime: InputMethodRuntime {
    var isSelected = false
    /// Modes the user added in System Settings. KeyHue only reads this.
    var enabledIDs: [String] = []
    var isReady: Bool { Set(enabledIDs).isSuperset(of: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]) }
    var isRegistered = true
    var events: [String] = []
    var failRegistration = false
    var failVerificationAt: Int?
    var verificationCount = 0
    var verifiedURLs: [URL] = []
    var failStop = false
    var reselectOnStop = false
    var suspendStop = false
    var stopContinuation: CheckedContinuation<Void, Never>?
    /// Simulates the user or macOS changing state while the service terminates / registers.
    var onStop: (() -> Void)?
    var onRegister: (() -> Void)?
    func verify(_ bundle: URL) throws {
        verificationCount += 1
        verifiedURLs.append(bundle)
        events.append("verify")
        if verificationCount == failVerificationAt { throw InputMethodManagementError.invalidBundle }
    }
    func stop() async throws {
        events.append("stop")
        if suspendStop { await withCheckedContinuation { stopContinuation = $0 } }
        onStop?()
        if failStop { throw InputMethodManagementError.stillRunning }
        if reselectOnStop { isSelected = true }
    }
    func register(_ bundle: URL) throws {
        events.append("register")
        onRegister?()
        if failRegistration { throw InputMethodManagementError.systemFailure }
    }
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
    func makeBundle(_ url: URL, version: String, bundleID: String = InputMethodIntegration.bundleID) throws {
        let files = FileManager.default
        try files.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/KeyHueInputMethodSpike"))
        let metadata: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "KeyHueInputMethodSpike", "LSBackgroundOnly": true,
                                     "InputMethodServerControllerClass": "KeyHueSpikeInputController", "InputMethodConnectionName": "KeyHueInputMethodSpike_Connection",
                                     "CFBundleShortVersionString": version, "CFBundleVersion": "42"]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    func infoPlist(_ url: URL) throws -> Data { try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) }
    /// Install verifies the payload first, then the staged candidate.
    var staging: URL? { runtime.verifiedURLs.count > 1 ? runtime.verifiedURLs[1].deletingLastPathComponent() : nil }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite("Bundled input method management")
struct InputMethodManagerTests {
    private let modes = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]

    @Test func installRegistersWithoutAddingInputSources() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        #expect(f.manager.status.hasPayload)
        #expect(!f.manager.status.isInstalled)
        #expect(try await !f.manager.install())
        #expect(f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
        #expect(f.runtime.events == ["verify", "verify", "stop", "verify", "register"])
        #expect(f.runtime.enabledIDs.isEmpty)
        #expect(f.manager.requiresRelaunch)
    }

    @Test func modesTheUserAlreadyAddedMakeTheInstallationReady() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.enabledIDs = modes
        #expect(try await f.manager.install())
        #expect(f.runtime.enabledIDs == modes)
    }

    @Test func unchangedInstallationWaitingForTheUserIsANoOp() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.events = []
        #expect(try await !f.manager.install())
        #expect(f.runtime.events == ["verify"])
        #expect(!f.manager.requiresRelaunch)
        f.runtime.enabledIDs = modes
        f.runtime.events = []
        #expect(try await f.manager.install())
        #expect(f.runtime.events == ["verify"])
        #expect(!f.manager.requiresRelaunch)
    }

    @Test func missingCatalogOnAnUnchangedInstallationRegistersOnce() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.isRegistered = false
        f.runtime.events = []
        #expect(try await !f.manager.install())
        #expect(f.runtime.events == ["verify", "register"])
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
        _ = try await install.value
        #expect(f.runtime.events.filter { $0 == "register" }.count == 1)
    }

    @Test func removalWaitsUntilTheUserRemovesBothModes() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        for remaining in [modes, [InputMethodIntegration.latinID]] {
            f.runtime.enabledIDs = remaining
            f.runtime.events = []
            await #expect(throws: InputMethodManagementError.inputSourcesInUse) { try await f.manager.uninstall() }
            #expect(f.manager.status.isInstalled)
            #expect(f.manager.status.hasRegisteredSources)
            #expect(!f.runtime.events.contains("stop"))
            #expect(f.runtime.enabledIDs == remaining)
        }
    }

    @Test func leftoverParentEntryDoesNotBlockRemoval() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.enabledIDs = [InputMethodIntegration.bundleID]
        #expect(!f.manager.status.hasRegisteredSources)
        try await f.manager.uninstall()
        #expect(!f.manager.status.isInstalled)
    }

    @Test func missingFilesWithUserModesAskForManualRemovalAndOtherwiseDoNothing() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.enabledIDs = [InputMethodIntegration.hangulID]
        #expect(!f.manager.status.isInstalled)
        #expect(f.manager.status.hasRegisteredSources)
        await #expect(throws: InputMethodManagementError.inputSourcesInUse) { try await f.manager.uninstall() }
        f.runtime.enabledIDs = []
        try await f.manager.uninstall()
        #expect(f.runtime.events.isEmpty)
        #expect(!f.manager.requiresRelaunch)
    }

    @Test func removalRefusesReselectionDuringTerminationAndKeepsFiles() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.reselectOnStop = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
    }

    @Test func updatesExistingLegacyServiceInSameLocation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        f.runtime.enabledIDs = modes
        #expect(f.manager.status.needsUpdate)
        #expect(try await f.manager.install())
        #expect(!f.manager.status.needsUpdate)
        #expect(f.runtime.events.contains("register"))
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

    @Test func failedRegistrationRestoresPreviousFiles() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        let original = try Data(contentsOf: f.manager.destination.appendingPathComponent("Contents/Info.plist"))
        f.runtime.failRegistration = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
        #expect(try Data(contentsOf: f.manager.destination.appendingPathComponent("Contents/Info.plist")) == original)
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

    @Test func removalThenReinstallUsesPackagedPayload() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        try await f.manager.uninstall()
        #expect(!f.manager.status.isInstalled)
        _ = try await f.manager.install()
        #expect(f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
    }

    @Test func stagedBundlesStayOutsideTheWatchedInputMethodsDirectory() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        let staged = f.runtime.verifiedURLs[1]
        #expect(!staged.path.hasPrefix(f.manager.destination.deletingLastPathComponent().path + "/"))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func uninstallOnlyStopsAndDeletesTheInstalledServiceAndPreservesPackagedApp() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.events = []
        try await f.manager.uninstall()
        #expect(f.runtime.events == ["verify", "stop"])
        #expect(!f.manager.status.isInstalled)
        #expect(f.manager.status.hasPayload)
        #expect(f.manager.requiresRelaunch)
    }

    @Test func failedTerminationKeepsInstalledService() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.failStop = true
        await #expect(throws: InputMethodManagementError.self) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
    }

    // MARK: - Status cache

    @Test func statusNoticesFilesChangedOutsideAnOperation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        #expect(f.manager.status.isInstalled)
        try FileManager.default.removeItem(at: f.manager.destination)
        #expect(!f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
        try f.makeBundle(f.manager.destination, version: "1.0.0")
        #expect(f.manager.status.isInstalled)
        #expect(f.manager.status.needsUpdate)
        try FileManager.default.removeItem(at: f.manager.destination)
        try f.makeBundle(f.manager.destination, version: "2.0.0", bundleID: "another.app")
        #expect(!f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
        try FileManager.default.removeItem(at: f.manager.payload)
        #expect(!f.manager.status.hasPayload)
    }

    @Test func installRedoesTheTransactionWhenTheInstalledCopyChangesBetweenCalls() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        _ = f.manager.status
        try FileManager.default.removeItem(at: f.manager.destination)
        f.runtime.events = []
        _ = try await f.manager.install()
        #expect(f.runtime.events == ["verify", "verify", "stop", "verify", "register"])
        #expect(f.manager.status.isInstalled)
        try FileManager.default.removeItem(at: f.manager.destination)
        try f.makeBundle(f.manager.destination, version: "1.0.0")
        f.runtime.events = []
        _ = try await f.manager.install()
        #expect(f.runtime.events == ["verify", "verify", "stop", "verify", "register"])
        #expect(!f.manager.status.needsUpdate)
        #expect(try f.infoPlist(f.manager.destination) == f.infoPlist(f.manager.payload))
    }

    // MARK: - Install location ownership

    @Test func plainFileAtTheInstallLocationIsNeitherReplacedNorDeleted() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.manager.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userData = Data("not a bundle".utf8)
        try userData.write(to: URL(fileURLWithPath: f.manager.destination.path))
        #expect(!f.manager.status.isInstalled)
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await f.manager.install() }
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await f.manager.uninstall() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.manager.destination.path)) == userData)
        #expect(!f.runtime.events.contains("stop"))
        #expect(!f.runtime.events.contains("register"))
        #expect(!f.manager.requiresRelaunch)
    }

    @Test func symlinkToAnOwnedBundleIsNotTreatedAsTheInstallation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        let elsewhere = f.root.appendingPathComponent("Elsewhere/" + InputMethodManager.appName, isDirectory: true)
        try f.makeBundle(elsewhere, version: "2.0.0")
        try FileManager.default.createDirectory(at: f.manager.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: f.manager.destination.path), withDestinationURL: elsewhere)
        #expect(!f.manager.status.isInstalled)
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await f.manager.install() }
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await f.manager.uninstall() }
        #expect(!f.runtime.events.contains("stop"))
        #expect(!f.runtime.events.contains("register"))
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Contents/Info.plist").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.manager.destination.path) == elsewhere.path)
    }

    @Test func installRefusesWhenThePayloadIsTheInstallLocationOrInsideIt() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("KeyHue.app")
        let original = try f.infoPlist(f.manager.payload)
        let same = InputMethodManager(appURL: app, installDirectory: app.appendingPathComponent("Contents/Helpers"), runtime: f.runtime)
        #expect(same.payload.path == same.destination.path)
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await same.install() }
        // The install directory reaches the payload only through a symlink.
        let link = f.root.appendingPathComponent("LinkedInputMethods")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app.appendingPathComponent("Contents/Helpers"))
        let linked = InputMethodManager(appURL: app, installDirectory: link, runtime: f.runtime)
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await linked.install() }
        // An owned, older installed bundle that contains the running app's payload.
        let outer = f.root.appendingPathComponent("Outer", isDirectory: true)
        let nested = InputMethodManager(appURL: outer.appendingPathComponent(InputMethodManager.appName + "/Contents/Resources/KeyHue.app"),
                                        installDirectory: outer, runtime: f.runtime)
        try f.makeBundle(nested.payload, version: "2.0.0")
        try f.makeBundle(nested.destination, version: "1.0.0")
        #expect(nested.payload.path.hasPrefix(nested.destination.path + "/"))
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await nested.install() }
        #expect(!f.runtime.events.contains("stop"))
        #expect(!f.runtime.events.contains("register"))
        #expect(try f.infoPlist(f.manager.payload) == original)
        #expect(try f.infoPlist(nested.payload) == original)
    }

    @Test func installNeverWritesInsideThePackagedPayload() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("KeyHue.app")
        let inside = InputMethodManager(appURL: app, installDirectory: f.manager.payload.appendingPathComponent("Contents/Resources"), runtime: f.runtime)
        #expect(inside.destination.path.hasPrefix(inside.payload.path + "/"))
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await inside.install() }
        #expect(!FileManager.default.fileExists(atPath: inside.destination.path))
        #expect(!f.runtime.events.contains("stop"))
    }

    @Test func uninstallNeverDeletesThePackagedPayload() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("KeyHue.app")
        let helpers = f.manager.payload.deletingLastPathComponent()
        for directory in [helpers, f.manager.payload.appendingPathComponent("Contents/Resources")] {
            let overlapping = InputMethodManager(appURL: app, installDirectory: directory, runtime: f.runtime)
            await #expect(throws: InputMethodManagementError.invalidBundle) { try await overlapping.uninstall() }
            #expect(FileManager.default.fileExists(atPath: f.manager.payload.path))
            #expect(!f.runtime.events.contains("stop"))
        }
    }

    // MARK: - Update transaction failures

    @Test func updateFailuresBeforeTheSwapKeepTheOldServiceAndRemoveStaging() async throws {
        enum Failure: CaseIterable { case candidateVerification, stop, reselectedDuringStop }
        for failure in Failure.allCases {
            let f = try InstallationFixture(); defer { f.cleanup() }
            try f.makeBundle(f.manager.destination, version: "0.0.1")
            let original = try f.infoPlist(f.manager.destination)
            switch failure {
            case .candidateVerification: f.runtime.failVerificationAt = 2
            case .stop: f.runtime.failStop = true
            case .reselectedDuringStop: f.runtime.reselectOnStop = true
            }
            await #expect(throws: InputMethodManagementError.self) { try await f.manager.install() }
            #expect(try f.infoPlist(f.manager.destination) == original, "\(failure)")
            #expect(f.manager.status.needsUpdate, "\(failure)")
            #expect(!f.runtime.events.contains("register"), "\(failure)")
            #expect(f.runtime.events.contains("stop") == (failure != .candidateVerification), "\(failure)")
            #expect(!f.manager.requiresRelaunch, "\(failure)")
            let staging = try #require(f.staging)
            #expect(!FileManager.default.fileExists(atPath: staging.path), "\(failure)")
        }
    }

    @Test func updateFailingFinalVerificationRestoresAndReRegistersThePreviousVersion() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        let original = try f.infoPlist(f.manager.destination)
        f.runtime.failVerificationAt = 3
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await f.manager.install() }
        #expect(try f.infoPlist(f.manager.destination) == original)
        #expect(f.runtime.events == ["verify", "verify", "stop", "verify", "register"])
        #expect(f.manager.status.isInstalled)
        #expect(f.manager.status.needsUpdate)
        let staging = try #require(f.staging)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func failedRegistrationReRegistersTheRestoredVersionAndRemovesStaging() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        f.runtime.failRegistration = true
        await #expect(throws: InputMethodManagementError.systemFailure) { try await f.manager.install() }
        #expect(f.runtime.events == ["verify", "verify", "stop", "verify", "register", "register"])
        #expect(f.manager.status.needsUpdate)
        let staging = try #require(f.staging)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func failedRestoreKeepsThePreviousVersionInStaging() async throws {
        let f = try InstallationFixture()
        let directory = f.manager.destination.deletingLastPathComponent()
        var staging: URL?
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            if let staging { try? FileManager.default.removeItem(at: staging) }
            f.cleanup()
        }
        try f.makeBundle(f.manager.destination, version: "0.0.1")
        let original = try f.infoPlist(f.manager.destination)
        // Neither the new copy can be removed nor the backup moved back.
        f.runtime.onRegister = { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path) }
        f.runtime.failRegistration = true
        await #expect(throws: InputMethodManagementError.systemFailure) { try await f.manager.install() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        staging = f.staging
        let previous = try #require(staging).appendingPathComponent("previous.app")
        #expect(try f.infoPlist(previous) == original)
    }

    @Test func failedReRegistrationOfAnUnchangedInstallationKeepsFilesAndCanBeRetried() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.isRegistered = false
        f.runtime.failRegistration = true
        f.runtime.events = []
        await #expect(throws: InputMethodManagementError.systemFailure) { try await f.manager.install() }
        #expect(f.runtime.events == ["verify", "register"])
        #expect(f.manager.status.isInstalled)
        #expect(!f.manager.status.needsUpdate)
        f.runtime.failRegistration = false
        f.runtime.enabledIDs = modes
        f.runtime.events = []
        #expect(try await f.manager.install())
        #expect(f.runtime.events == ["verify", "register"])
        #expect(f.manager.requiresRelaunch)
        f.runtime.isRegistered = true
        f.runtime.events = []
        #expect(try await f.manager.install())
        #expect(f.runtime.events == ["verify"])
        #expect(!f.manager.requiresRelaunch)
    }

    // MARK: - Removal

    @Test func removalRefusesModesAddedWhileTheServiceStops() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        let runtime = f.runtime
        runtime.onStop = { [unowned runtime] in runtime.enabledIDs = [InputMethodIntegration.hangulID] }
        runtime.events = []
        await #expect(throws: InputMethodManagementError.inputSourcesInUse) { try await f.manager.uninstall() }
        #expect(runtime.events == ["verify", "stop"])
        #expect(f.manager.status.isInstalled)
        #expect(f.manager.status.hasRegisteredSources)
        #expect(!f.manager.requiresRelaunch)
    }

    @Test func removalOfASelectedOrUnverifiableServiceKeepsItRunning() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        f.runtime.isSelected = true
        f.runtime.events = []
        await #expect(throws: InputMethodManagementError.activeSource) { try await f.manager.uninstall() }
        #expect(f.runtime.events.isEmpty)
        f.runtime.isSelected = false
        f.runtime.reselectOnStop = true
        await #expect(throws: InputMethodManagementError.activeSource) { try await f.manager.uninstall() }
        #expect(f.manager.status.isInstalled)
        #expect(!f.manager.requiresRelaunch)
        f.runtime.isSelected = false
        f.runtime.reselectOnStop = false
        f.runtime.failVerificationAt = f.runtime.verificationCount + 1
        f.runtime.events = []
        await #expect(throws: InputMethodManagementError.invalidBundle) { try await f.manager.uninstall() }
        #expect(f.runtime.events == ["verify"])
        #expect(f.manager.status.isInstalled)
    }

    @Test func requiresRelaunchIsResetAtTheStartOfEveryOperation() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        _ = try await f.manager.install()
        #expect(f.manager.requiresRelaunch)
        try await f.manager.uninstall()
        #expect(f.manager.requiresRelaunch)
        try await f.manager.uninstall()
        #expect(!f.manager.requiresRelaunch)
        _ = try await f.manager.install()
        #expect(f.manager.requiresRelaunch)
        f.runtime.isSelected = true
        await #expect(throws: InputMethodManagementError.activeSource) { try await f.manager.uninstall() }
        #expect(!f.manager.requiresRelaunch)
    }

    // MARK: - Operation lock

    @Test func aFailedOperationReleasesTheLockButRefusedCallsDoNot() async throws {
        let f = try InstallationFixture(); defer { f.cleanup() }
        f.runtime.suspendStop = true
        f.runtime.failStop = true
        let install = Task { try await f.manager.install() }
        for _ in 0..<100 where f.runtime.stopContinuation == nil { await Task.yield() }
        let continuation = try #require(f.runtime.stopContinuation)
        // A refused call must not clear the in-flight operation's lock.
        await #expect(throws: InputMethodManagementError.systemFailure) { try await f.manager.uninstall() }
        await #expect(throws: InputMethodManagementError.systemFailure) { try await f.manager.install() }
        await #expect(throws: InputMethodManagementError.systemFailure) { try await f.manager.uninstall() }
        f.runtime.suspendStop = false
        continuation.resume()
        await #expect(throws: InputMethodManagementError.stillRunning) { try await install.value }
        #expect(!FileManager.default.fileExists(atPath: f.manager.destination.path))
        f.runtime.failStop = false
        _ = try await f.manager.install()
        #expect(f.manager.status.isInstalled)
        try await f.manager.uninstall()
        #expect(!f.manager.status.isInstalled)
    }
}
