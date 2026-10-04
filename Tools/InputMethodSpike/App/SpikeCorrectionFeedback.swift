import Foundation
import InputMethodKit
import KeyHueCore

/// ADR 0065: tells the utility about failures (app and reason only) and records
/// undone corrections on this Mac when the user turned recording on. Words never
/// travel in notifications: other apps of the same user can observe those.
enum SpikeCorrectionFeedback {
    private static let fileQueue = DispatchQueue(label: "io.github.sejoung.keyhue.inputmethod.undone-corrections")

    static func reportFailure(_ reason: CorrectionFailure, client: any IMKTextInput) {
        guard let app = client.bundleIdentifier(), !app.isEmpty else { return }
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
            let url = UndoneCorrectionLog.fileURL()
            var log = UndoneCorrectionLog(data: try? Data(contentsOf: url))
            log.append(entry)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try log.encoded().write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
