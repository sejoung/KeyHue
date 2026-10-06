import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
struct InputSourceWorkerTests {
    func withWorker(_ body: String, name: String = "KeyHue", test: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueWorkerTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(name)
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

    private func snapshotJSON(currentID: String?, sources: [InputMethodSourceState], enabledIDs: [String]) throws -> String {
        let snapshot = InputSourceDiagnosticSnapshot(enabledIDs: enabledIDs, currentID: currentID, sources: sources)
        return String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    }
    private func printing(_ json: String) -> String { "cat <<'EOF'\n\(json)\nEOF" }
    private var readyCatalog: [InputMethodSourceState] {
        InputMethodSourcePreferences.ownedIDs.map {
            InputMethodSourceState(id: $0, enabled: true, selectable: $0 != InputMethodIntegration.bundleID, enableCapable: true)
        }
    }
    private let modes = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]

    @Test func validJSONFromAFailedWorkerIsRejected() throws {
        let json = try snapshotJSON(currentID: nil, sources: readyCatalog, enabledIDs: modes)
        try withWorker(printing(json) + "\nexit 3") { url in
            #expect(InputSourceController.freshSnapshot(workerExecutable: url) == nil)
        }
        try withWorker(printing(json) + "\necho noise >&2") { url in
            #expect(InputSourceController.freshSnapshot(workerExecutable: url)?.isReady == true)
        }
    }

    @Test func workersReceiveOnlyTheirOperationArguments() throws {
        let json = try snapshotJSON(currentID: nil, sources: readyCatalog, enabledIDs: modes)
        try withWorker("[ \"$#\" = 1 ] && [ \"$1\" = --keyhue-input-source-status ] || exit 9\n" + printing(json)) { url in
            #expect(InputSourceController.freshSnapshot(workerExecutable: url) != nil)
        }
        try withWorker("[ \"$#\" = 2 ] && [ \"$1\" = --keyhue-select-input-source ] && [ \"$2\" = \(modes[0]) ] || exit 9") { url in
            #expect(InputSourceController.selectFresh(sourceID: modes[0], workerExecutable: url))
            #expect(!InputSourceController.selectFresh(sourceID: modes[1], workerExecutable: url))
        }
        #expect(!InputSourceController.selectFresh(sourceID: modes[0], workerExecutable: nil))
        #expect(InputSourceController.freshSnapshot(workerExecutable: nil) == nil)
    }

    @Test func onlyTheKeyHueExecutableIsUsedAsTheStatusWorker() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueWorkerMarker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let json = try snapshotJSON(currentID: nil, sources: readyCatalog, enabledIDs: modes)
        try withWorker("touch '\(marker.path)'\n" + printing(json), name: "KeyHueInputMethodSpike") { url in
            #expect(InputSourceController.freshSnapshot(workerExecutable: url) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aWorkerIgnoringTerminationIsKilledWithinABoundedTime() throws {
        try withWorker("trap '' TERM\n/bin/sleep 3") { url in
            let start = Date()
            #expect(InputSourceWorker.run(executable: url, arguments: [], timeout: 0.05) == nil)
            #expect(Date().timeIntervalSince(start) < 1.5)
        }
    }

    @Test func largeWorkerOutputIsReadCompletely() throws {
        // More than a pipe buffer (64 KiB) of output must not stall the worker until the timeout.
        try withWorker("head -c 200000 /dev/zero | tr '\\0' ' '\nprintf '{}'") { url in
            let start = Date()
            let result = InputSourceWorker.run(executable: url, arguments: [], timeout: 1)
            #expect(result?.status == 0)
            #expect(result?.output.count == 200_002)
            #expect(Date().timeIntervalSince(start) < 1)
        }
    }

    @Test func aChildHoldingTheOutputOpenCannotBlockTheCallerPastTheTimeout() throws {
        // The worker exits, but a background child inherits stdout and keeps it open.
        try withWorker("sleep 5 &\nprintf '{}'") { url in
            let start = Date()
            let result = InputSourceWorker.run(executable: url, arguments: [], timeout: 1)
            #expect(result?.status == 0)
            #expect(result?.output == Data("{}".utf8))
            #expect(Date().timeIntervalSince(start) < 1.5)
        }
    }

    @Test func systemRuntimeFailsClosedWhenTheWorkerCannotProveTheCurrentSource() throws {
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { [] as [[String: Any]] })
        var cases: [(String, Bool)] = [("exit 1", true), ("printf garbage", true)]
        for current in [nil, InputMethodIntegration.bundleID] + modes {
            cases.append((printing(try snapshotJSON(currentID: current, sources: readyCatalog, enabledIDs: modes)), true))
        }
        for current in [InputMethodIntegration.abcID, "another.inputmethod.Hangul"] {
            cases.append((printing(try snapshotJSON(currentID: current, sources: readyCatalog, enabledIDs: modes)), false))
        }
        for (body, selected) in cases {
            try withWorker(body) { url in
                let runtime = SystemInputMethodRuntime(preferences: preferences, workerExecutable: url)
                #expect(runtime.isSelected == selected, "\(body)")
            }
        }
    }

    @Test func systemRuntimeReadinessAndRegistrationComeFromTheWorkerCatalog() throws {
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { [] as [[String: Any]] })
        let cases: [(String, ready: Bool, registered: Bool)] = [
            ("exit 1", false, false),
            ("printf garbage", false, false),
            (printing(try snapshotJSON(currentID: nil, sources: readyCatalog, enabledIDs: modes)), true, true),
            (printing(try snapshotJSON(currentID: nil, sources: readyCatalog, enabledIDs: [])), false, true),
            (printing(try snapshotJSON(currentID: nil, sources: Array(readyCatalog.dropFirst()), enabledIDs: modes)), false, false)
        ]
        for (body, ready, registered) in cases {
            try withWorker(body) { url in
                let runtime = SystemInputMethodRuntime(preferences: preferences, workerExecutable: url)
                #expect(runtime.isReady == ready, "\(body)")
                #expect(runtime.isRegistered == registered, "\(body)")
            }
        }
    }
}
