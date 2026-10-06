import AppKit
import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

/// ADR 0065: what the utility does with failures and undone corrections.
@MainActor
@Suite("Correction feedback store", .serialized)
struct CorrectionFeedbackStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keyhue-undone-\(UUID().uuidString)/undone-corrections.json")
    }

    private func makeModel(_ store: SettingsStore, _ feedback: CorrectionFeedbackStore) -> SettingsModel {
        let model = SettingsModel(
            store: store, actions: AppEdgeDecliningActions(),
            updates: UpdateChecker(currentVersion: "0.9.0", defaults: makeTestDefaults(), scheduler: FakeScheduler()) {
                throw GitHubReleaseFetcher.Failure.invalidResponse
            },
            feedback: feedback
        ) { [.abc, .korean2Set] }
        model.reload()
        return model
    }

    private let entry = UndoneCorrection(original: "rkskek", corrected: "가나다", app: "com.apple.TextEdit",
                                         mode: .automatic, date: Date(timeIntervalSince1970: 1_000_000))

    private func writeLog(_ entries: [UndoneCorrection], to url: URL) throws {
        var log = UndoneCorrectionLog()
        for entry in entries.reversed() { log.append(entry) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try log.encoded().write(to: url)
    }

    // MARK: failures

    @Test func failuresAreKeptAcrossLaunches() {
        let defaults = makeTestDefaults()
        let feedback = CorrectionFeedbackStore(defaults: defaults, undoneFile: temporaryFile())
        #expect(feedback.recordFailure(CorrectionFailureEvent(app: "com.example.Web", reason: .replacementIgnored)) == .show)
        let reloaded = CorrectionFeedbackStore(defaults: defaults, undoneFile: temporaryFile())
        #expect(reloaded.failures.map(\.app) == ["com.example.Web"])
    }

    @Test func excludingAFailedAppAddsItToTheListAndClearsItsRecord() {
        let store = SettingsStore(defaults: makeTestDefaults())
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: temporaryFile())
        _ = feedback.recordFailure(CorrectionFailureEvent(app: "com.example.Web", reason: .unexpectedResult))
        let model = makeModel(store, feedback)
        model.excludeFailedApp("com.example.Web")
        #expect(store.settings.correctionExcludedApps.contains("com.example.Web"))
        #expect(feedback.failures.isEmpty)
    }

    @Test func tryingAgainClearsOnlyThatApp() {
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: temporaryFile())
        _ = feedback.recordFailure(CorrectionFailureEvent(app: "a", reason: .textUnavailable))
        _ = feedback.recordFailure(CorrectionFailureEvent(app: "b", reason: .textUnavailable))
        feedback.clearFailures(app: "a")
        #expect(feedback.failures.map(\.app) == ["b"])
    }

    // MARK: undone corrections

    @Test func undoneCorrectionsAreReadFromTheInputMethodsFile() throws {
        let file = temporaryFile()
        try writeLog([entry], to: file)
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: file)
        feedback.reloadUndone()
        #expect(feedback.undone == [entry])
    }

    @Test func neverCorrectingAWordAddsAnExceptionAndRemovesTheEntry() throws {
        let file = temporaryFile()
        try writeLog([entry], to: file)
        let store = SettingsStore(defaults: makeTestDefaults())
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: file)
        let model = makeModel(store, feedback)
        feedback.reloadUndone()
        model.neverCorrect(entry)
        #expect(store.settings.correctionIgnoredWords == ["rkskek"])
        #expect(feedback.undone.isEmpty)
        // The last entry gone, the file is gone too: no typed word stays on disk.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        model.neverCorrect(entry) // no duplicate exception
        #expect(store.settings.correctionIgnoredWords == ["rkskek"])
    }

    @Test func removingAnExceptionWord() {
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.correctionIgnoredWords = ["rkskek", "dkTek"] }
        let model = makeModel(store, CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: temporaryFile()))
        model.removeIgnoredWord("rkskek")
        #expect(store.settings.correctionIgnoredWords == ["dkTek"])
    }

    /// Turning recording off deletes the file: no typed word stays on disk.
    @Test func turningRecordingOffDeletesTheFile() throws {
        let file = temporaryFile()
        try writeLog([entry], to: file)
        let store = SettingsStore(defaults: makeTestDefaults())
        store.update { $0.recordUndoneCorrections = true }
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: file)
        let model = makeModel(store, feedback)
        feedback.reloadUndone()
        model.recordUndoneBinding.wrappedValue = false
        #expect(!store.settings.recordUndoneCorrections)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(feedback.undone.isEmpty)
    }

    @Test func removingOneOrAllUndoneEntries() throws {
        let file = temporaryFile()
        let other = UndoneCorrection(original: "dkTek", corrected: "앗다", app: "a", mode: .manual, date: entry.date)
        try writeLog([entry, other], to: file)
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: file)
        feedback.reloadUndone()
        feedback.removeUndone(entry)
        #expect(feedback.undone == [other])
        feedback.clearUndone()
        #expect(feedback.undone.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: notices

    /// A failure notice uses the warning's place, with a title and a caption and no word.
    @Test func aNoticeShowsItsTitleAndCaption() {
        let toast = WrongLanguageToast(scheduler: FakeScheduler())
        defer { toast.hideNow() }
        toast.showNotice(title: "Couldn't fix the word", caption: "TextEdit kept it as typed.",
                         color: RGBAColor(hex: "#8E8E93")!, on: NSScreen.main)
        #expect(toast.word == "Couldn't fix the word")
        #expect(toast.caption == "TextEdit kept it as typed.")
        #expect(toast.isShowing)
    }

    @Test(arguments: [CorrectionFailureNotice.show, .suggestExclusion])
    func failureNoticesNameTheApp(_ notice: CorrectionFailureNotice) {
        let text = CorrectionFeedbackStore.noticeText(notice, reason: .replacementIgnored, appName: "Chrome")
        #expect(text != nil)
        #expect(text.map { $0.title.contains("Chrome") || $0.caption.contains("Chrome") } == true)
    }

    /// ADR 0067: in a terminal the input method needs Accessibility to erase with keys.
    /// The notice says what to allow instead of blaming the app.
    @Test func aMissingKeyPermissionSaysWhatToAllow() throws {
        let text = try #require(CorrectionFeedbackStore.noticeText(.show, reason: .keyPermission, appName: "Ghostty"))
        #expect(text.title == L("Word Fixing Needs Accessibility Access"))
        #expect(text.caption.contains("Ghostty"))
        // Not an app problem: no suggestion to exclude the app.
        let third = try #require(CorrectionFeedbackStore.noticeText(.suggestExclusion, reason: .keyPermission, appName: "Ghostty"))
        #expect(third.title == text.title)
    }

    /// ADR 0068: the shortcut found nothing; the hint says where to point.
    @Test func nothingToFixSaysWhatToPointAt() throws {
        let text = try #require(CorrectionFeedbackStore.noticeText(.show, reason: .nothingToFix, appName: "TextEdit"))
        #expect(text.title == L("No Word to Fix"))
        #expect(text.caption == L("Put the cursor right after the word, or select the text."))
    }

    /// ADR 0071: in a terminal the word is on screen, but the input method never
    /// received its keys (typed while its session was closed). Say what to do.
    @Test func nothingToFixInATerminalSaysToTypeAgain() throws {
        let text = try #require(CorrectionFeedbackStore.noticeText(.show, reason: .nothingToFix, appName: "Ghostty", isTerminal: true))
        #expect(text.title == L("No Word to Fix"))
        #expect(text.caption == L("In a terminal, only keys the input method received can be fixed. Type the word again, then press the shortcut."))
    }

    @Test func aQuietFailureShowsNothing() {
        #expect(CorrectionFeedbackStore.noticeText(.quiet, reason: .replacementIgnored, appName: "Chrome") == nil)
    }

    // MARK: reports

    @Test func reportsNameOnlyWhatTheUserChose() throws {
        let feedback = CorrectionFeedbackStore(defaults: makeTestDefaults(), undoneFile: temporaryFile())
        _ = feedback.recordFailure(CorrectionFailureEvent(app: "com.example.Web", reason: .replacementIgnored))
        let record = try #require(feedback.failures.first)
        let failureURL = try #require(feedback.reportURL(for: record))
        #expect(failureURL.absoluteString.contains("com.example.Web"))
        #expect(!failureURL.absoluteString.contains("rkskek"))
        let falsePositiveURL = feedback.reportURL(for: entry)
        #expect(falsePositiveURL.absoluteString.contains("rkskek"))
    }
}
