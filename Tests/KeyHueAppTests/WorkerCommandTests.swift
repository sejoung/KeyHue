import Foundation
import Testing
@testable import KeyHueApp

@Suite("Internal worker command parsing")
struct WorkerCommandTests {
    @Test func normalLaunchesStartTheApp() {
        for arguments in [[], ["-NSDocumentRevisionsDebugMode", "YES"], [WorkerCommand.finishSetupFlag], ["--keyhue-unknown"]] {
            #expect(WorkerCommand.parse(arguments) == .app)
            #expect(!WorkerCommand.isWorker(arguments))
        }
    }

    @Test func selectNeedsExactlyOneNonEmptyID() {
        #expect(WorkerCommand.parse([WorkerCommand.selectFlag, "com.apple.keylayout.ABC"]) == .worker(.selectInputSource(id: "com.apple.keylayout.ABC")))
        for arguments in [[WorkerCommand.selectFlag], [WorkerCommand.selectFlag, ""], [WorkerCommand.selectFlag, "a", "b"]] {
            #expect(WorkerCommand.parse(arguments) == .invalid)
        }
    }

    /// The same session repair as the app, for the opt-in TextEdit acceptance (ADR 0062).
    @Test func repairingSelectNeedsExactlyOneNonEmptyID() {
        let id = "io.github.sejoung.keyhue.inputmethod.spike.Hangul"
        #expect(WorkerCommand.parse([WorkerCommand.selectRepairingFlag, id]) == .worker(.selectInputSourceRepairing(id: id)))
        for arguments in [[WorkerCommand.selectRepairingFlag], [WorkerCommand.selectRepairingFlag, ""], [WorkerCommand.selectRepairingFlag, "a", "b"]] {
            #expect(WorkerCommand.parse(arguments) == .invalid)
        }
    }

    /// ADR 0074: the uninstall script's step inside this app's process.
    @Test func loginItemStatusTakesNoArguments() {
        #expect(WorkerCommand.parse([WorkerCommand.loginItemStatusFlag]) == .worker(.loginItemStatus))
        #expect(WorkerCommand.parse([WorkerCommand.loginItemStatusFlag, "extra"]) == .invalid)
    }

    @Test func prepareUninstallTakesNoArguments() {
        #expect(WorkerCommand.parse([WorkerCommand.prepareUninstallFlag]) == .worker(.prepareUninstall))
        #expect(WorkerCommand.parse([WorkerCommand.prepareUninstallFlag, "extra"]) == .invalid)
        #expect(WorkerCommand.isWorker([WorkerCommand.prepareUninstallFlag]))
    }

    /// ADR 0077: a new process posts a terminal fix's keys when this one has an old permission answer.
    @Test func postBackspacesNeedsAProcessAndACountInRange() {
        #expect(WorkerCommand.parse([WorkerCommand.postBackspacesFlag, "1514", "6"]) == .worker(.postBackspaces(pid: 1514, count: 6)))
        for arguments in [[WorkerCommand.postBackspacesFlag], [WorkerCommand.postBackspacesFlag, "1514"],
                          [WorkerCommand.postBackspacesFlag, "0", "1"], [WorkerCommand.postBackspacesFlag, "1514", "0"],
                          [WorkerCommand.postBackspacesFlag, "1514", "257"], [WorkerCommand.postBackspacesFlag, "x", "1"],
                          [WorkerCommand.postBackspacesFlag, "1514", "1", "extra"]] {
            #expect(WorkerCommand.parse(arguments) == .invalid)
        }
    }

    @Test func statusTakesNoArguments() {
        #expect(WorkerCommand.parse([WorkerCommand.statusFlag]) == .worker(.inputSourceStatus))
        #expect(WorkerCommand.parse([WorkerCommand.statusFlag, "extra"]) == .invalid)
    }

    @Test func relaunchNeedsAPositivePIDAndAMode() {
        #expect(WorkerCommand.parse([WorkerCommand.relaunchFlag, "42", "setup"]) == .worker(.relaunchAfterInputMethod(parentPID: 42, finishSetup: true)))
        #expect(WorkerCommand.parse([WorkerCommand.relaunchFlag, "42", "plain"]) == .worker(.relaunchAfterInputMethod(parentPID: 42, finishSetup: false)))
        for arguments in [
            [WorkerCommand.relaunchFlag], [WorkerCommand.relaunchFlag, "42"], [WorkerCommand.relaunchFlag, "42", "setup", "x"],
            [WorkerCommand.relaunchFlag, "0", "setup"], [WorkerCommand.relaunchFlag, "-1", "setup"],
            [WorkerCommand.relaunchFlag, "abc", "setup"], [WorkerCommand.relaunchFlag, "99999999999", "setup"],
            [WorkerCommand.relaunchFlag, " 42", "setup"], [WorkerCommand.relaunchFlag, "42", "Setup"], [WorkerCommand.relaunchFlag, "42", ""]
        ] {
            #expect(WorkerCommand.parse(arguments) == .invalid, "\(arguments)")
        }
    }

    @Test func workerFlagsOnlyCountInFirstPosition() {
        #expect(WorkerCommand.parse(["-flag", WorkerCommand.statusFlag]) == .app)
    }

    @Test func malformedWorkerInvocationsAreStillWorkers() {
        #expect(WorkerCommand.isWorker([WorkerCommand.selectFlag]))
        #expect(WorkerCommand.isWorker([WorkerCommand.relaunchFlag, "x", "y"]))
    }

    @Test func relaunchArgumentsRoundTripThroughTheParser() {
        for finishSetup in [true, false] {
            let arguments = WorkerCommand.relaunchArguments(parentPID: 1234, finishSetup: finishSetup)
            #expect(WorkerCommand.parse(arguments) == .worker(.relaunchAfterInputMethod(parentPID: 1234, finishSetup: finishSetup)))
        }
    }

    @Test func relaunchOpensANewInstanceAndPassesSetupOnlyWhenAsked() {
        #expect(WorkerCommand.relaunchOpenArguments(bundlePath: "/Applications/Key Hue.app", finishSetup: false) == ["-n", "/Applications/Key Hue.app"])
        let setup = WorkerCommand.relaunchOpenArguments(bundlePath: "/Applications/KeyHue.app", finishSetup: true)
        #expect(setup == ["-n", "/Applications/KeyHue.app", "--args", WorkerCommand.finishSetupFlag])
        // The relaunched app must not be mistaken for a worker.
        #expect(WorkerCommand.parse(Array(setup.dropFirst(3))) == .app)
    }

    @Test func onlyTheInstalledAppBodyWritesTheLogFile() {
        #expect(Log.writesFile(bundleID: "io.github.sejoung.keyhue", arguments: []))
        #expect(Log.writesFile(bundleID: "io.github.sejoung.keyhue", arguments: [WorkerCommand.finishSetupFlag]))
        #expect(!Log.writesFile(bundleID: nil, arguments: []))
        #expect(!Log.writesFile(bundleID: "com.apple.dt.xctest.tool", arguments: []))
        #expect(!Log.writesFile(bundleID: "io.github.sejoung.keyhue.inputmethod.spike", arguments: []))
        for worker in [[WorkerCommand.statusFlag], [WorkerCommand.selectFlag, "id"], [WorkerCommand.relaunchFlag, "1", "plain"], [WorkerCommand.selectFlag]] {
            #expect(!Log.writesFile(bundleID: "io.github.sejoung.keyhue", arguments: worker))
        }
    }
}
