import Foundation
import InputMethodKit
import KeyHueCore

/// ADR 0065: tells the utility about failures (app and reason only) and records
/// undone corrections on this Mac when the user turned recording on. Words never
/// travel in notifications: other apps of the same user can observe those.
enum SpikeCorrectionFeedback {
    private static let fileQueue = DispatchQueue(label: "io.github.sejoung.keyhue.inputmethod.undone-corrections")

    static func reportFailure(_ reason: CorrectionFailure, client: any IMKTextInput) {
        reportFailure(reason, app: client.bundleIdentifier())
    }

    static func reportFailure(_ reason: CorrectionFailure, app: String?) {
        guard let app, !app.isEmpty else { return }
        SpikeLog.notice("correction failed app=\(app) reason=\(reason.rawValue)")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(CorrectionFailure.notification), object: nil,
            userInfo: reason.userInfo(app: app), deliverImmediately: true)
    }

    /// An immediate undo: a likely false positive. Stored only if recording is on.
    static func recordUndone(original: String, corrected: String, mode: CorrectionMode, client: any IMKTextInput) {
        guard SpikeCorrectionSettings.shared.recordUndone, let app = client.bundleIdentifier(), !app.isEmpty else { return }
        let entry = UndoneCorrection(original: original, corrected: corrected, app: app, mode: mode, date: Date())
        fileQueue.async {
            do {
                // The utility may remove an entry at the same time; the shared lock keeps both changes.
                try UndoneCorrectionLog.update(at: UndoneCorrectionLog.fileURL()) { $0.append(entry) }
            } catch {
                SpikeLog.error("undone correction not recorded")
                return
            }
            SpikeLog.notice("undone correction recorded app=\(app) mode=\(mode.rawValue)")
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(UndoneCorrectionLog.changedNotification), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }
}
