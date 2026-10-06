import Foundation

// ADR 0065: correction failures and false positives are shown to the user, who
// decides what to do. Nothing here is sent anywhere automatically.

/// Why the input method could not correct a word in an app. No text.
public enum CorrectionFailure: String, Codable, CaseIterable, Sendable {
    /// The app did not report the word's text or the caret.
    case textUnavailable
    /// The app ignored the replacement; the original stayed.
    case replacementIgnored
    /// The text after the replacement was not what was requested.
    case unexpectedResult
    /// Automatic: the Korean mode request was not applied; the original was restored.
    case modeNotApplied
    /// A terminal: the input method has no Accessibility access to erase with keys (ADR 0067).
    case keyPermission
    /// The shortcut found no word before the caret and no selection (ADR 0068).
    /// Not the app's fault: shown, never recorded.
    case nothingToFix

    /// Posted by the input method; the utility shows and records it.
    public static let notification = "io.github.sejoung.keyhue.inputmethod.correction-failed"

    /// The app ID and the reason name only.
    public func userInfo(app: String) -> [String: String] {
        ["app": app, "reason": rawValue]
    }

    public static func from(userInfo: [AnyHashable: Any]?) -> CorrectionFailureEvent? {
        guard let app = userInfo?["app"] as? String, !app.isEmpty,
              let reason = (userInfo?["reason"] as? String).flatMap(CorrectionFailure.init(rawValue:)) else { return nil }
        return CorrectionFailureEvent(app: app, reason: reason)
    }
}

public struct CorrectionFailureEvent: Equatable, Sendable {
    public let app: String
    public let reason: CorrectionFailure

    public init(app: String, reason: CorrectionFailure) {
        self.app = app
        self.reason = reason
    }
}

/// What the utility shows for a failure.
public enum CorrectionFailureNotice: Equatable, Sendable {
    /// A short message that the word was left as typed.
    case show
    /// The third failure in this app: suggest excluding it, once.
    case suggestExclusion
    /// Already suggested: stay quiet until the user clears the app's record.
    case quiet
}

/// The utility's record of failures per app ("고치지 못한 앱"). Apps and reasons only.
public struct CorrectionFailureLog: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public let app: String
        public var count: Int
        public var lastReason: CorrectionFailure
        public var lastDate: Date
        public var suggested: Bool
    }

    public static let suggestionThreshold = 3
    /// UserDefaults key in the utility.
    public static let defaultsKey = "correctionFailureLog"

    /// Most recent first.
    public private(set) var records: [Record] = []

    public init() {}

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public mutating func record(app: String, reason: CorrectionFailure, at date: Date) -> CorrectionFailureNotice {
        if reason == .nothingToFix { return .show } // the user's situation, not the app's failure (ADR 0068)
        var record = records.first { $0.app == app }
            ?? Record(app: app, count: 0, lastReason: reason, lastDate: date, suggested: false)
        records.removeAll { $0.app == app }
        record.count += 1
        record.lastReason = reason
        record.lastDate = date
        let notice: CorrectionFailureNotice
        if reason == .keyPermission {
            // Missing permission is not the app's fault: listed (with "Allow…") but never
            // escalated to "exclude this app" or silenced (ADR 0077).
            notice = .show
        } else if record.suggested {
            notice = .quiet
        } else if record.count >= Self.suggestionThreshold {
            record.suggested = true
            notice = .suggestExclusion
        } else {
            notice = .show
        }
        records.insert(record, at: 0)
        return notice
    }

    /// "Try again": forget this app's failures.
    public mutating func clear(app: String) {
        records.removeAll { $0.app == app }
    }

    public mutating func clearAll() {
        records = []
    }
}

/// A correction the user undid right away: a likely false positive. Contains the
/// typed word, so it is stored only when the user turned recording on.
public struct UndoneCorrection: Codable, Equatable, Hashable, Sendable {
    public let original: String
    public let corrected: String
    public let app: String
    public let mode: CorrectionMode
    public let date: Date

    public init(original: String, corrected: String, app: String, mode: CorrectionMode, date: Date) {
        self.original = original
        self.corrected = corrected
        self.app = app
        self.mode = mode
        self.date = date
    }
}

extension CorrectionMode: Codable {}

/// The undone corrections file, written by the input method and read by the utility.
public struct UndoneCorrectionLog: Codable, Equatable, Sendable {
    public static let limit = 50
    /// Posted (without payload) when the file changed. Words never travel in notifications.
    public static let changedNotification = "io.github.sejoung.keyhue.inputmethod.undone-corrections-changed"

    /// `~/Library/Application Support/KeyHue/undone-corrections.json`, readable only by the user.
    public static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/KeyHue/undone-corrections.json")
    }

    /// Newest first.
    public private(set) var entries: [UndoneCorrection] = []

    public init() {}

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public mutating func append(_ entry: UndoneCorrection) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func remove(_ entry: UndoneCorrection) {
        entries.removeAll { $0 == entry }
    }
}

/// Prefilled GitHub issue pages. The user reads and edits them in the browser and
/// submits them; KeyHue never sends a report itself.
public enum CorrectionReport {
    static let newIssue = "https://github.com/sejoung/KeyHue/issues/new"

    public static func failure(app: String, appVersion: String?, reason: CorrectionFailure, count: Int,
                               keyHueVersion: String, macOSVersion: String) -> URL {
        issue(title: "Word fixing failed in \(app)", body: """
            The input method could not fix words in this app (ADR 0065).

            - App: \(app) \(appVersion ?? "(version unknown)")
            - Reason: \(reason.rawValue)
            - Failures: \(count)
            - KeyHue: \(keyHueVersion)
            - macOS: \(macOSVersion)
            """)
    }

    public static func falsePositive(_ entry: UndoneCorrection, keyHueVersion: String, macOSVersion: String) -> URL {
        issue(title: "Wrong word fix: \(entry.original) → \(entry.corrected)", body: """
            This word was typed on purpose and should not be fixed (ADR 0065).

            - Typed: \(entry.original)
            - Changed to: \(entry.corrected)
            - Mode: \(entry.mode.rawValue)
            - App: \(entry.app)
            - KeyHue: \(keyHueVersion)
            - macOS: \(macOSVersion)
            """)
    }

    private static func issue(title: String, body: String) -> URL {
        var components = URLComponents(string: newIssue)!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        // "+" survives URLQueryItem but reads as a space on the server; encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
