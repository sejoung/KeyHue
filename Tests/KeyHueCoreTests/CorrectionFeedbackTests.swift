import Foundation
import Testing
@testable import KeyHueCore

/// ADR 0065: failures and false positives are shown to the user, who decides.
@Suite("Correction feedback")
struct CorrectionFeedbackTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: failures (app and reason only)

    /// Each failure is shown until the third in the same app, which suggests
    /// excluding the app once; after that the app is quiet until its record is cleared.
    @Test func failuresAreShownThenSuggestOnceThenStayQuiet() {
        var log = CorrectionFailureLog()
        #expect(log.record(app: "com.example.Web", reason: .replacementIgnored, at: now) == .show)
        #expect(log.record(app: "com.example.Web", reason: .unexpectedResult, at: now) == .show)
        #expect(log.record(app: "com.example.Web", reason: .replacementIgnored, at: now) == .suggestExclusion)
        #expect(log.record(app: "com.example.Web", reason: .replacementIgnored, at: now) == .quiet)
        #expect(log.records.first?.count == 4)
        #expect(log.records.first?.lastReason == .replacementIgnored)
        // Another app has its own count.
        #expect(log.record(app: "com.example.Other", reason: .textUnavailable, at: now) == .show)
        // Clearing ("try again") starts over.
        log.clear(app: "com.example.Web")
        #expect(log.record(app: "com.example.Web", reason: .replacementIgnored, at: now) == .show)
    }

    /// ADR 0068: "no word before the caret" is the user's situation, not the app's
    /// failure. It is shown every time and never recorded.
    @Test func nothingToFixIsShownButNeverRecorded() {
        var log = CorrectionFailureLog()
        for _ in 0..<4 { #expect(log.record(app: "com.example.Web", reason: .nothingToFix, at: now) == .show) }
        #expect(log.records.isEmpty)
    }

    @Test func theMostRecentFailureIsListedFirst() {
        var log = CorrectionFailureLog()
        _ = log.record(app: "a", reason: .textUnavailable, at: now)
        _ = log.record(app: "b", reason: .textUnavailable, at: now.addingTimeInterval(1))
        _ = log.record(app: "a", reason: .textUnavailable, at: now.addingTimeInterval(2))
        #expect(log.records.map(\.app) == ["a", "b"])
    }

    @Test func theFailureLogSurvivesEncodingAndIgnoresDamage() throws {
        var log = CorrectionFailureLog()
        _ = log.record(app: "com.example.Web", reason: .modeNotApplied, at: now)
        let restored = CorrectionFailureLog(data: try log.encoded())
        #expect(restored == log)
        #expect(CorrectionFailureLog(data: Data("not json".utf8)) == CorrectionFailureLog())
        #expect(CorrectionFailureLog(data: nil) == CorrectionFailureLog())
    }

    /// The notification carries the app and a reason name only.
    @Test func failureNotificationsCarryAppAndReasonOnly() {
        let info = CorrectionFailure.replacementIgnored.userInfo(app: "com.example.Web")
        #expect(Set(info.keys) == ["app", "reason"])
        #expect(CorrectionFailure.from(userInfo: info) == CorrectionFailureEvent(app: "com.example.Web", reason: .replacementIgnored))
        #expect(CorrectionFailure.from(userInfo: ["app": "x", "reason": "nonsense"]) == nil)
        #expect(CorrectionFailure.from(userInfo: ["reason": "textUnavailable"]) == nil)
    }

    // MARK: undone corrections (words, only when the user turned recording on)

    @Test func undoneCorrectionsKeepTheMostRecentFifty() {
        var log = UndoneCorrectionLog()
        for index in 0..<(UndoneCorrectionLog.limit + 5) {
            log.append(UndoneCorrection(original: "w\(index)", corrected: "가", app: "a", mode: .automatic, date: now))
        }
        #expect(log.entries.count == UndoneCorrectionLog.limit)
        #expect(log.entries.first?.original == "w\(UndoneCorrectionLog.limit + 4)") // newest first
        #expect(!log.entries.contains { $0.original == "w0" })
    }

    @Test func undoneCorrectionsCanBeRemovedAndSurviveEncoding() throws {
        var log = UndoneCorrectionLog()
        let entry = UndoneCorrection(original: "rkskek", corrected: "가나다", app: "com.apple.TextEdit", mode: .manual, date: now)
        log.append(entry)
        #expect(UndoneCorrectionLog(data: try log.encoded()) == log)
        log.remove(entry)
        #expect(log.entries.isEmpty)
        #expect(UndoneCorrectionLog(data: Data("[{\"broken\":1}]".utf8)) == UndoneCorrectionLog())
    }

    // MARK: reports (opened in the browser by the user; never sent automatically)

    @Test func aFailureReportNamesAppReasonAndVersionsOnly() throws {
        let url = CorrectionReport.failure(app: "com.example.Web", appVersion: "3.2", reason: .replacementIgnored, count: 4,
                                           keyHueVersion: "0.2.5", macOSVersion: "26.0")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/sejoung/KeyHue/issues/new")
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        for part in ["com.example.Web", "3.2", "replacementIgnored", "4", "0.2.5", "26.0"] { #expect(body.contains(part)) }
    }

    @Test func aFalsePositiveReportContainsTheChosenWordAndIsEncoded() throws {
        let entry = UndoneCorrection(original: "a&b=c", corrected: "가 나", app: "com.apple.TextEdit", mode: .automatic, date: now)
        let url = CorrectionReport.falsePositive(entry, keyHueVersion: "0.2.5", macOSVersion: "26.0")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("a&b=c"))
        #expect(body.contains("가 나"))
        #expect(body.contains("automatic"))
        #expect(components.queryItems?.contains { $0.name == "title" } == true)
    }

    /// ADR 0077: three fixes without KeyHue's Accessibility access must keep saying what
    /// to allow, not suggest excluding the terminal and then go quiet.
    @Test func missingPermissionIsListedButNeverEscalated() {
        var log = CorrectionFailureLog()
        let date = Date(timeIntervalSince1970: 0)
        for _ in 0..<5 {
            #expect(log.record(app: "com.mitchellh.ghostty", reason: .keyPermission, at: date) == .show)
        }
        #expect(log.records.first?.count == 5)
        #expect(log.records.first?.suggested == false)
    }

    /// ADR 0078: a selection in a terminal is the user's situation, not the app's failure.
    @Test func terminalSelectionIsShownButNeverRecorded() {
        var log = CorrectionFailureLog()
        #expect(log.record(app: "com.mitchellh.ghostty", reason: .terminalSelection, at: Date(timeIntervalSince1970: 0)) == .show)
        #expect(log.records.isEmpty)
    }
}
