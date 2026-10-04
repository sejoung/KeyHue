import Foundation
import Testing
@testable import KeyHueCore

/// ADR 0064: the utility owns the correction setting; the input method reads the
/// same stored values with the same rules (it runs as a separate process).
@MainActor
@Suite("Input method correction settings")
struct InputMethodCorrectionSettingsTests {
    @Test func manualIsTheDefault() {
        #expect(KeyHueSettings().inputMethodCorrection == .manual)
    }

    /// Terminals and code editors are excluded from the start; the user can change it.
    @Test func terminalsAndCodeEditorsAreExcludedByDefault() {
        let excluded = Set(KeyHueSettings().correctionExcludedApps)
        for app in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                    "com.microsoft.VSCode", "com.apple.dt.Xcode"] {
            #expect(excluded.contains(app))
        }
    }

    @Test func storedValuesSurviveAReload() {
        let defaults = makeTestDefaults()
        SettingsStore(defaults: defaults).update {
            $0.inputMethodCorrection = .automatic
            $0.correctionExcludedApps = ["com.example.Editor"]
        }
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.inputMethodCorrection == .automatic)
        #expect(reloaded.correctionExcludedApps == ["com.example.Editor"])
    }

    /// Defaults are not stored (ADR 0014): a later default change reaches untouched settings.
    @Test func defaultsAreNotStored() {
        let defaults = makeTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.update { $0.inputMethodCorrection = .off }
        store.update { $0.inputMethodCorrection = .manual }
        #expect(defaults.object(forKey: InputMethodCorrection.Key.mode) == nil)
        #expect(defaults.object(forKey: InputMethodCorrection.Key.excludedApps) == nil)
    }

    /// An empty list is a real choice (correct everywhere) and is stored.
    @Test func anEmptyExclusionListIsKept() {
        let defaults = makeTestDefaults()
        SettingsStore(defaults: defaults).update { $0.correctionExcludedApps = [] }
        #expect(SettingsStore(defaults: defaults).settings.correctionExcludedApps.isEmpty)
    }

    @Test func malformedValuesFallBackAndAreReported() {
        let defaults = makeTestDefaults()
        defaults.set("sometimes", forKey: InputMethodCorrection.Key.mode)
        defaults.set("com.apple.Terminal", forKey: InputMethodCorrection.Key.excludedApps)
        let store = SettingsStore(defaults: defaults)
        #expect(store.settings.inputMethodCorrection == .manual)
        #expect(store.settings.correctionExcludedApps == InputMethodCorrection.defaultExcludedApps)
        #expect(Set(store.ignoredKeys).isSuperset(of: [InputMethodCorrection.Key.mode, InputMethodCorrection.Key.excludedApps]))
    }

    // MARK: ADR 0065

    /// Nothing about typed words is kept unless the user turns recording on.
    @Test func undoneCorrectionsAreNotRecordedByDefault() {
        #expect(!KeyHueSettings().recordUndoneCorrections)
        #expect(KeyHueSettings().correctionIgnoredWords.isEmpty)
    }

    @Test func exceptionWordsAndRecordingSurviveAReload() {
        let defaults = makeTestDefaults()
        SettingsStore(defaults: defaults).update {
            $0.correctionIgnoredWords = ["rkskek"]
            $0.recordUndoneCorrections = true
        }
        let reloaded = SettingsStore(defaults: defaults).settings
        #expect(reloaded.correctionIgnoredWords == ["rkskek"])
        #expect(reloaded.recordUndoneCorrections)
    }

    @Test func theInputMethodReadsExceptionWordsAndRecording() {
        let read = InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: ["rkskek", ""], recordUndone: true)
        #expect(read.ignoredWords == ["rkskek"])
        #expect(read.recordUndone)
        // Same rules as SettingsStore: `defaults write` text works, anything else is off.
        #expect(InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: nil, recordUndone: "yes").recordUndone)
        let malformed = InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: 7, recordUndone: "maybe")
        #expect(malformed.ignoredWords.isEmpty)
        #expect(!malformed.recordUndone)
    }

    /// Reported false positives ship with the app: one word per line, `#` comments.
    @Test func reportedWordsAreParsedFromTheShippedList() {
        let text = "# reported false positives\nrkskek\n\n  dkTek  \n# note\n"
        #expect(InputMethodCorrection.reportedWords(from: text) == ["rkskek", "dkTek"])
    }

    // MARK: what the input method reads

    @Test func theInputMethodReadsTheSameValues() {
        let read = InputMethodCorrection.read(mode: "automatic", excludedApps: ["com.example.Editor", ""], ignoredWords: nil, recordUndone: nil)
        #expect(read.mode == .automatic)
        #expect(read.excludedApps == ["com.example.Editor"]) // blank entries are not apps
    }

    @Test func theInputMethodFallsBackToDefaultsForMissingOrMalformedValues() {
        let missing = InputMethodCorrection.read(mode: nil, excludedApps: nil, ignoredWords: nil, recordUndone: nil)
        #expect(missing.mode == .manual)
        #expect(missing.excludedApps == Set(InputMethodCorrection.defaultExcludedApps))
        let malformed = InputMethodCorrection.read(mode: 3, excludedApps: "com.apple.Terminal", ignoredWords: 7, recordUndone: nil)
        #expect(malformed.mode == .manual)
        #expect(malformed.excludedApps == Set(InputMethodCorrection.defaultExcludedApps))
    }
}
