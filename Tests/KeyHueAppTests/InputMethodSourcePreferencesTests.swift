import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
@Suite("Scoped macOS 26 input source membership (read-only)")
struct InputMethodSourcePreferencesTests {
    private var hangul: [String: Any] { ["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.hangulID] }
    private var parent: [String: Any] { ["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Keyboard Input Method"] }

    @Test func readsOwnedEntriesAndIgnoresOtherSources() {
        let other: [String: Any] = ["Bundle ID": "other.inputmethod", "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.hangulID]
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { [other, self.parent, self.hangul] })
        #expect(preferences.enabledIDs == [InputMethodIntegration.bundleID, InputMethodIntegration.hangulID])
    }

    @Test func unavailableReadAndUnknownOwnedEntriesAreNotTreatedAsAnEmptyList() {
        for value: Any in [NSNull(), "bad", [["Bundle ID": InputMethodIntegration.bundleID]],
                           [["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Input Mode", "Input Mode": "future.mode"]]] {
            let preferences = InputMethodSourcePreferences(isSupported: true, read: { value })
            #expect(preferences.enabledIDs == nil)
        }
    }

    @Test func unsupportedOSNeverReadsTheDomain() {
        var reads = 0
        let preferences = InputMethodSourcePreferences(isSupported: false, read: { reads += 1; return [] as [[String: Any]] })
        #expect(preferences.enabledIDs == nil)
        #expect(reads == 0)
    }

    @Test func manualChangesInSystemSettingsBecomeVisibleAfterInvalidation() {
        var value: Any = [] as [[String: Any]]
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { value })
        #expect(preferences.enabledIDs == [])
        value = [hangul]
        #expect(preferences.enabledIDs == [])
        preferences.invalidate()
        #expect(preferences.enabledIDs == [InputMethodIntegration.hangulID])
    }

    private var latin: [String: Any] { ["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.latinID] }

    @Test func ownedEntriesWithExtraKeysOrRepeatedAreStillRead() {
        func extra(_ entry: [String: Any]) -> [String: Any] { entry.merging(["Future Key": 1, "Display": "x"]) { $1 } }
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { [extra(self.parent), extra(self.hangul), self.latin, self.hangul] })
        let ids = preferences.enabledIDs
        #expect(ids != nil)
        #expect(Set(ids ?? []) == Set(InputMethodSourcePreferences.ownedIDs))
        #expect(ids?.allSatisfy(InputMethodSourcePreferences.ownedIDs.contains) == true)
    }

    @Test func malformedOrUnrelatedForeignEntriesStayOpaque() {
        let foreign: [[String: Any]] = [
            [:],
            ["Bundle ID": 5, "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.hangulID],
            ["InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": 0, "KeyboardLayout Name": "ABC"],
            ["Bundle ID": "com.apple.inputmethod.Korean", "InputSourceKind": "Input Mode", "Input Mode": "com.apple.inputmethod.Korean.2SetKorean"],
            ["Bundle ID": "other.inputmethod", "InputSourceKind": "Something New", "Input Mode": ["nested"]]
        ]
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { foreign + [self.latin] })
        #expect(preferences.enabledIDs == [InputMethodIntegration.latinID])
        let onlyForeign = InputMethodSourcePreferences(isSupported: true, read: { foreign })
        #expect(onlyForeign.enabledIDs == [])
    }

    @Test func missingKeyMeansNoThirdPartyModes() {
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { nil })
        #expect(preferences.enabledIDs == [])
    }

    @Test func ownedEntriesInAnUnknownShapeRejectTheWholeList() {
        let unknown: [[String: Any]] = [
            ["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Keyboard Input Method", "Input Mode": InputMethodIntegration.hangulID],
            ["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Input Mode", "Input Mode": 1],
            ["Bundle ID": InputMethodIntegration.bundleID, "Input Mode": InputMethodIntegration.latinID],
            ["Bundle ID": InputMethodIntegration.bundleID, "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.bundleID]
        ]
        for entry in unknown {
            let preferences = InputMethodSourcePreferences(isSupported: true, read: { [self.parent, self.hangul, entry] })
            #expect(preferences.enabledIDs == nil, "\(entry)")
        }
        let mixed = InputMethodSourcePreferences(isSupported: true, read: { [self.hangul, "not a dictionary"] as [Any] })
        #expect(mixed.enabledIDs == nil)
    }

    @Test func readsAreCachedIncludingFailuresUntilInvalidated() {
        var reads = 0
        var value: Any? = NSNull()
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { reads += 1; return value })
        #expect(preferences.enabledIDs == nil)
        #expect(preferences.enabledIDs == nil)
        #expect(reads == 1)
        value = [hangul]
        #expect(preferences.enabledIDs == nil)
        #expect(reads == 1)
        preferences.invalidate()
        #expect(preferences.enabledIDs == [InputMethodIntegration.hangulID])
        #expect(preferences.enabledIDs == [InputMethodIntegration.hangulID])
        #expect(reads == 2)
        value = NSNull()
        preferences.invalidate()
        #expect(preferences.enabledIDs == nil)
        #expect(reads == 3)
    }

    @Test func systemRuntimeUsesConfiguredMembershipWhenReadable() {
        for (value, expected) in [([parent], [InputMethodIntegration.bundleID]), ([], []), ([hangul, latin], [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])] as [([[String: Any]], [String])] {
            let preferences = InputMethodSourcePreferences(isSupported: true, read: { value })
            let runtime = SystemInputMethodRuntime(preferences: preferences, workerExecutable: nil)
            #expect(runtime.enabledIDs == expected)
        }
    }
}
