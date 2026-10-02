import Foundation
import Testing
@testable import KeyHueApp

@MainActor
struct InputSourceWorkerTests {
    func withWorker(_ body: String, test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueWorkerTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("KeyHue")
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try test(executable)
    }

    @Test func nonzeroExitMalformedEmptyOrIncompleteJSONNeverProvesReadiness() throws {
        for body in ["exit 7", "printf 'garbage'", "exit 0", "printf '{}'", "printf '{\"enabledIDs\":[]}'"] {
            try withWorker(body) { url in
                #expect(InputSourceController.freshSnapshot(workerExecutable: url) == nil)
            }
        }
    }
    @Test func validWorkerPreservesNativeEvidenceAndForeignCurrentSource() throws {
        try withWorker("printf '%s' '{\"enabledIDs\":[],\"sources\":[],\"currentID\":\"other.source\"}'") { url in
            let snapshot = try #require(InputSourceController.freshSnapshot(workerExecutable: url))
            #expect(snapshot.currentID == "other.source")
            #expect(!snapshot.isReady)
        }
    }
    @Test func unavailableExecutableAndFailedSelectionReturnFailure() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/KeyHue")
        #expect(InputSourceController.freshSnapshot(workerExecutable: missing) == nil)
        #expect(!InputSourceController.selectFresh(sourceID: "unavailable", workerExecutable: missing))
        try withWorker("exit 1") { url in
            #expect(!InputSourceController.selectFresh(sourceID: "unavailable", workerExecutable: url))
        }
    }
    @Test func aHungWorkerIsTerminatedWithinABoundedTime() throws {
        try withWorker("exec /bin/sleep 5") { url in
            let start = Date()
            #expect(InputSourceWorker.run(executable: url, arguments: [], timeout: 0.05) == nil)
            #expect(Date().timeIntervalSince(start) < 1)
        }
    }
}
