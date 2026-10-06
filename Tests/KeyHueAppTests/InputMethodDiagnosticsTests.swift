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
            InputMethodSourceState(id: InputMethodIntegration.bundleID, enabled: bit(0), selectable: false, enableCapable: true),
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
            InputMethodSourceState(id: $0, enabled: true, selectable: $0 != InputMethodIntegration.bundleID, enableCapable: true)
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

    private var readyCatalog: [InputMethodSourceState] {
        InputMethodSourcePreferences.ownedIDs.map {
            InputMethodSourceState(id: $0, enabled: true, selectable: $0 != InputMethodIntegration.bundleID, enableCapable: true)
        }
    }
    private let modes = [InputMethodIntegration.hangulID, InputMethodIntegration.latinID]

    @Test func configuredMembershipNeverChangesNativeReadiness() {
        for configured in [nil, [], InputMethodSourcePreferences.ownedIDs, ["another.inputmethod"]] as [[String]?] {
            var s = InputSourceDiagnosticSnapshot(enabledIDs: modes, currentID: nil, sources: readyCatalog, configuredIDs: configured)
            #expect(s.isReady, "\(String(describing: configured))")
            s.sources[0].enabled = false
            #expect(!s.isReady, "\(String(describing: configured))")
        }
        let unsupported = InputSourceDiagnosticSnapshot(enabledIDs: modes, currentID: nil, sources: readyCatalog, configuredIDs: nil)
        #expect(unsupported.logDescription.contains("configured=unsupported"))
        #expect(unsupported.logDescription.contains("ready=true"))
    }

    @Test func repeatedOrForeignNativeIDsAndTheCurrentSourceDoNotAffectReadiness() {
        for current in [nil, InputMethodIntegration.hangulID, InputMethodIntegration.abcID] {
            let s = InputSourceDiagnosticSnapshot(enabledIDs: modes + modes + [InputMethodIntegration.abcID, InputMethodIntegration.bundleID],
                                                  currentID: current, sources: readyCatalog)
            #expect(s.isReady)
        }
        // The parent in the native roster cannot stand in for a mode.
        let parentOnly = InputSourceDiagnosticSnapshot(enabledIDs: [InputMethodIntegration.bundleID, InputMethodIntegration.hangulID], currentID: nil, sources: readyCatalog)
        #expect(!parentOnly.isReady)
    }

    @Test func aParentThatIsAlsoSelectableIsStillOnlyOneRequiredEntry() {
        var catalog = readyCatalog
        catalog[0].selectable = true
        #expect(InputSourceDiagnosticSnapshot(enabledIDs: modes, currentID: nil, sources: catalog).isReady)
        catalog[0].enableCapable = false
        catalog[1].enableCapable = false
        #expect(InputSourceDiagnosticSnapshot(enabledIDs: modes, currentID: nil, sources: catalog).isReady)
    }

    @Test func logDescriptionIsIndependentOfCatalogOrder() {
        let a = InputSourceDiagnosticSnapshot(enabledIDs: modes, currentID: InputMethodIntegration.abcID, sources: readyCatalog, configuredIDs: [])
        let b = InputSourceDiagnosticSnapshot(enabledIDs: modes, currentID: InputMethodIntegration.abcID, sources: readyCatalog.reversed(), configuredIDs: [])
        #expect(a.logDescription == b.logDescription)
        #expect(a.logDescription.contains("current=\(InputMethodIntegration.abcID)"))
    }

    @Test func workerJSONWithoutOptionalOrWithUnknownFieldsStillDecodes() throws {
        let json = """
        {"enabledIDs":["\(modes[0])","\(modes[1])"],"futureField":{"x":1},"sources":[
        {"id":"\(InputMethodIntegration.bundleID)","enabled":true,"selectable":false,"enableCapable":true,"extra":0},
        {"id":"\(modes[0])","enabled":true,"selectable":true,"enableCapable":true},
        {"id":"\(modes[1])","enabled":true,"selectable":true,"enableCapable":true}]}
        """
        let decoded = try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: Data(json.utf8))
        #expect(decoded.currentID == nil)
        #expect(decoded.configuredIDs == nil)
        #expect(decoded.isReady)
        let missingField = Data(#"{"enabledIDs":[],"sources":[{"id":"x","enabled":true,"selectable":true}]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: missingField) }
        let wrongType = Data(#"{"enabledIDs":"all","sources":[]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: wrongType) }
    }
}
