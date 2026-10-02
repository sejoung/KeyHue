import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
@Suite("Scoped macOS 26 input source membership (read-only)")
struct InputMethodSourcePreferencesTests {
    private var hangul: [String: Any] { ["Bundle ID": InputMethodManager.bundleID, "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.hangulID] }
    private var parent: [String: Any] { ["Bundle ID": InputMethodManager.bundleID, "InputSourceKind": "Keyboard Input Method"] }

    @Test func readsOwnedEntriesAndIgnoresOtherSources() {
        let other: [String: Any] = ["Bundle ID": "other.inputmethod", "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.hangulID]
        let preferences = InputMethodSourcePreferences(isSupported: true, read: { [other, self.parent, self.hangul] })
        #expect(preferences.enabledIDs == [InputMethodManager.bundleID, InputMethodIntegration.hangulID])
    }

    @Test func unavailableReadAndUnknownOwnedEntriesAreNotTreatedAsAnEmptyList() {
        for value: Any in [NSNull(), "bad", [["Bundle ID": InputMethodManager.bundleID]],
                           [["Bundle ID": InputMethodManager.bundleID, "InputSourceKind": "Input Mode", "Input Mode": "future.mode"]]] {
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
}
