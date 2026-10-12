import AppKit
import KeyHueCore

/// ADR 0065: the utility's side of correction feedback.
/// - Failures (apps and reasons only) are kept in the utility's defaults.
/// - Undone corrections are read from the input method's private file, which
///   exists only while the user records them. Nothing is sent automatically.
@MainActor
final class CorrectionFeedbackStore: ObservableObject {
    static let shared = CorrectionFeedbackStore(defaults: .standard, undoneFile: UndoneCorrectionLog.fileURL())

    @Published private(set) var failures: [CorrectionFailureLog.Record]
    @Published private(set) var undone: [UndoneCorrection] = []

    private var log: CorrectionFailureLog
    private let defaults: UserDefaults
    let undoneFile: URL

    init(defaults: UserDefaults, undoneFile: URL) {
        self.defaults = defaults
        self.undoneFile = undoneFile
        log = CorrectionFailureLog(data: defaults.data(forKey: CorrectionFailureLog.defaultsKey))
        failures = log.records
    }

    // MARK: failures

    func recordFailure(_ event: CorrectionFailureEvent) -> CorrectionFailureNotice {
        let notice = log.record(app: event.app, reason: event.reason, at: Date())
        saveFailures()
        return notice
    }

    func clearFailures(app: String) {
        log.clear(app: app)
        saveFailures()
    }

    private func saveFailures() {
        failures = log.records
        if log.records.isEmpty {
            defaults.removeObject(forKey: CorrectionFailureLog.defaultsKey)
        } else if let data = try? log.encoded() {
            defaults.set(data, forKey: CorrectionFailureLog.defaultsKey)
        }
    }

    // MARK: undone corrections

    func reloadUndone() {
        undone = UndoneCorrectionLog(data: try? Data(contentsOf: undoneFile)).entries
    }

    /// The input method may append at the same time; the shared lock keeps both changes.
    func removeUndone(_ entry: UndoneCorrection) {
        do {
            undone = try UndoneCorrectionLog.update(at: undoneFile) { $0.remove(entry) }.entries
        } catch {
            Log.app.error("undone correction not removed: \(error)")
            reloadUndone()
        }
    }

    /// Deletes the file: no typed word stays on disk.
    func clearUndone() {
        do {
            try UndoneCorrectionLog.update(at: undoneFile) { $0 = UndoneCorrectionLog() }
            undone = []
        } catch {
            Log.app.error("undone corrections not deleted: \(error)")
            reloadUndone()
        }
    }

    // MARK: notices

    /// What to show for a failure; nil when the app is quiet (already suggested).
    /// - Parameter isTerminal: terminals report no text; the word is only what the
    ///   input method received as keys (ADR 0068, 0071).
    static func noticeText(_ notice: CorrectionFailureNotice, reason: CorrectionFailure,
                           appName: String, isTerminal: Bool = false) -> (title: String, caption: String)? {
        if reason == .terminalSelection {
            return (L("Selected Text Can't Be Fixed Here"),
                    L("Terminals don't report a selection. Deselect, then press the shortcut right after the word."))
        }
        if reason == .nothingToFix {
            return (L("No Word to Fix"), isTerminal
                ? L("In a terminal, only keys the input method received can be fixed. Type the word again, then press the shortcut.")
                : L("Put the cursor right after the word, or select the text."))
        }
        // A missing permission is not the app's fault: say what to allow, never "exclude it".
        if reason == .keyPermission, notice != .quiet {
            return (L("Word Fixing Needs Accessibility Access"),
                    L("To fix words in %@, allow KeyHue in System Settings → Privacy & Security → Accessibility.", appName))
        }
        switch notice {
        case .show:
            return (L("Couldn't Fix the Word"), L("%@ kept the word as you typed it.", appName))
        case .suggestExclusion:
            return (L("Word Fixing Keeps Failing in %@", appName),
                    L("You can add it to Apps That Are Never Changed in Settings → Input Method."))
        case .quiet:
            return nil
        }
    }

    // MARK: reports

    func reportURL(for record: CorrectionFailureLog.Record) -> URL? {
        CorrectionReport.failure(app: record.app, appVersion: Self.version(of: record.app), reason: record.lastReason,
                                 count: record.count, keyHueVersion: Self.keyHueVersion, macOSVersion: Self.macOSVersion)
    }

    func reportURL(for entry: UndoneCorrection) -> URL {
        CorrectionReport.falsePositive(entry, keyHueVersion: Self.keyHueVersion, macOSVersion: Self.macOSVersion)
    }

    static var keyHueVersion: String {
        KeyHueProject.version() ?? "development"
    }

    static var macOSVersion: String {
        KeyHueProject.macOSVersion
    }

    /// The installed app's name, or the bundle ID when it is not installed.
    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func version(of app: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
            .flatMap { Bundle(url: $0).flatMap(KeyHueProject.version(of:)) }
    }
}
