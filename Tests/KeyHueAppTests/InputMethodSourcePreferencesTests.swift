import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
private final class PreferenceFixture {
    var value: Any?
    var writes = 0
    var notifications = 0
    var failWrite = false
    var corruptWrite = false
    lazy var preferences = InputMethodSourcePreferences(isSupported: true, read: { self.value }, write: {
        self.writes += 1
        if self.failWrite { self.failWrite = false; return false }
        if self.corruptWrite { self.value = "invalid"; self.corruptWrite = false } else { self.value = $0 }
        return true
    }, publish: { self.notifications += 1 })
}

@MainActor
@Suite("Scoped macOS 26 input source compatibility")
struct InputMethodSourcePreferencesTests {
    private var hangul: [String: Any] { ["Bundle ID": InputMethodManager.bundleID, "InputSourceKind": "Input Mode", "Input Mode": InputMethodIntegration.hangulID] }

    @Test func duplicateOwnedModesAreNormalizedAndUnknownRequestedIDsNeverWrite() throws {
        let f = PreferenceFixture()
        f.value = [hangul, hangul]
        #expect(try f.preferences.setEnabled([InputMethodIntegration.hangulID, InputMethodIntegration.hangulID]))
        #expect(f.preferences.enabledIDs == [InputMethodIntegration.hangulID])
        #expect(throws: InputMethodManagementError.self) { try f.preferences.setEnabled(["foreign.mode"]) }
        #expect(f.writes == 1)
    }

    @Test func unavailableReadAndMalformedOwnedEntriesCannotBecomeAnEmptyRoster() {
        for value: Any in [NSNull(), [["Bundle ID": InputMethodManager.bundleID]], [["Bundle ID": InputMethodManager.bundleID, "InputSourceKind": "Keyboard Input Method", "Input Mode": "unexpected"]]] {
            let f = PreferenceFixture(); f.value = value
            #expect(f.preferences.enabledIDs == nil)
            #expect(throws: InputMethodManagementError.self) { try f.preferences.setEnabled([]) }
            #expect(f.writes == 0)
        }
    }

    @Test func activationAddsMissingModesAndPreservesOtherEntriesAndOwnedMetadata() throws {
        let f = PreferenceFixture()
        let other: [String: Any] = ["Bundle ID": "other.inputmethod", "InputSourceKind": "Input Mode", "Input Mode": "other.inputmethod.Korean", "extra": ["value": 9]]
        var existing = hangul; existing["extra"] = "keep"
        f.value = [other, existing, other]
        #expect(try f.preferences.setEnabled(InputMethodSourcePreferences.ownedIDs))
        let saved = try #require(f.value as? [[String: Any]])
        #expect((saved.filter { $0["Bundle ID"] as? String == "other.inputmethod" } as NSArray).isEqual(to: [other, other]))
        #expect(saved.first { $0["Input Mode"] as? String == InputMethodIntegration.hangulID }?["extra"] as? String == "keep")
        #expect(Set(f.preferences.enabledIDs ?? []) == Set(InputMethodSourcePreferences.ownedIDs))
        #expect(f.notifications == 1)
    }

    @Test func removalCleansAnOrphanModeAndDoesNotChangeOtherSources() throws {
        let f = PreferenceFixture()
        let other: [String: Any] = ["Bundle ID": "other.inputmethod", "Input Mode": InputMethodIntegration.hangulID]
        f.value = [hangul, other]
        #expect(try f.preferences.setEnabled([]))
        #expect((try #require(f.value as? [[String: Any]]) as NSArray).isEqual(to: [other]))
        #expect(f.preferences.enabledIDs == [])
        #expect(try f.preferences.setEnabled([]))
        #expect(f.writes == 1)
    }

    @Test func unsupportedOSAndUnknownSchemaNeverWrite() throws {
        let f = PreferenceFixture()
        let unsupported = InputMethodSourcePreferences(isSupported: false, read: { f.value }, write: { _ in f.writes += 1; return true })
        #expect(try !unsupported.setEnabled([]))
        for value: Any in ["bad", [["Bundle ID": InputMethodManager.bundleID, "InputSourceKind": "Input Mode", "Input Mode": "future.mode"]]] {
            f.value = value
            f.preferences.invalidate()
            #expect(throws: InputMethodManagementError.self) { try f.preferences.setEnabled([]) }
            #expect(f.preferences.enabledIDs == nil)
        }
        #expect(f.writes == 0)
    }

    @Test func externalManualChangesBecomeVisibleAfterInvalidation() {
        let f = PreferenceFixture()
        f.value = [] as [[String: Any]]
        #expect(f.preferences.enabledIDs == [])
        f.value = [hangul]
        f.preferences.invalidate()
        #expect(f.preferences.enabledIDs == [InputMethodIntegration.hangulID])
    }

    @Test func failedWriteOrReadbackRestoresPreviousConfiguration() {
        for corrupt in [false, true] {
            let f = PreferenceFixture(); f.value = [hangul]
            f.failWrite = !corrupt; f.corruptWrite = corrupt
            #expect(throws: InputMethodManagementError.self) { try f.preferences.setEnabled([]) }
            #expect((f.value as? [[String: Any]] as NSArray?)?.isEqual(to: [hangul]) == true)
            #expect(f.preferences.enabledIDs == [InputMethodIntegration.hangulID])
        }
    }
}
