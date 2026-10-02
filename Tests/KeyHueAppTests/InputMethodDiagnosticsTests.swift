import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
struct InputMethodDiagnosticsTests {
    @Test(arguments: Array(0..<128))
    func readinessRequiresParentBothEnabledSelectableModesAndNativeRoster(_ bits: Int) {
        func bit(_ n: Int) -> Bool { bits & (1 << n) != 0 }
        let states = [
            InputMethodSourceState(id: InputMethodManager.bundleID, enabled: bit(0), selectable: false, enableCapable: true),
            InputMethodSourceState(id: InputMethodIntegration.hangulID, enabled: bit(1), selectable: bit(3), enableCapable: true),
            InputMethodSourceState(id: InputMethodIntegration.latinID, enabled: bit(2), selectable: bit(4), enableCapable: true)
        ]
        let ids = [bit(5) ? InputMethodIntegration.hangulID : nil, bit(6) ? InputMethodIntegration.latinID : nil].compactMap { $0 }
        let snapshot = InputSourceDiagnosticSnapshot(enabledIDs: ids, currentID: InputMethodIntegration.abcID,
            sources: states, configuredIDs: InputMethodSourcePreferences.ownedIDs)
        #expect(snapshot.isReady == (bits == 127))
    }

    @Test func configuredModesAndStaticSelectCapabilityCannotProveReadiness() {
        let snapshot = InputSourceDiagnosticSnapshot(enabledIDs: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID],
            currentID: nil, configuredIDs: InputMethodSourcePreferences.ownedIDs)
        #expect(!snapshot.isReady)
        #expect(snapshot.logDescription.contains("ready=false"))
    }

    @Test func missingDuplicateOrForeignCatalogEntriesCannotReplaceRequiredSources() {
        let required = InputMethodSourcePreferences.ownedIDs.map {
            InputMethodSourceState(id: $0, enabled: true, selectable: $0 != InputMethodManager.bundleID, enableCapable: true)
        }
        var s = InputSourceDiagnosticSnapshot(enabledIDs: Array(InputMethodSourcePreferences.ownedIDs.dropFirst()), currentID: nil, sources: required)
        #expect(s.isReady)
        for i in required.indices {
            s.sources = required; s.sources.remove(at: i)
            #expect(!s.isReady)
            s.sources = required + [required[i]]
            #expect(!s.isReady)
        }
        s.sources = required.reversed() + [InputMethodSourceState(id: "another.inputmethod", enabled: true, selectable: true, enableCapable: true)]
        #expect(s.isReady)
        s.sources = [InputMethodSourceState(id: "another.inputmethod.Hangul", enabled: true, selectable: true, enableCapable: true)]
        #expect(!s.isReady)
    }

    @Test func diagnosticJSONRoundTripKeepsEvidenceAndMalformedDataThrows() throws {
        let s = InputSourceDiagnosticSnapshot(enabledIDs: [], currentID: "other.source", configuredIDs: [])
        let decoded = try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded.currentID == "other.source")
        #expect(decoded.configuredIDs == [])
        #expect(!decoded.isReady)
        for data in [Data(), Data("{}".utf8), Data("not json".utf8)] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: data) }
        }
    }
}
