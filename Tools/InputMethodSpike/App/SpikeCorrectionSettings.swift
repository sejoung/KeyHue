import CoreGraphics
import Foundation
import KeyHueCore
import KeyHueInputMethodSpikeCore

/// The utility's correction setting, read by this separate process (ADR 0064).
/// Read when a correction client first activates and again whenever the utility
/// posts a change. Used only from the main thread, like every IMK callback here.
final class SpikeCorrectionSettings: NSObject, @unchecked Sendable {
    static let shared = SpikeCorrectionSettings()

    private(set) var mode = CorrectionMode.manual
    private(set) var excludedApps = Set(InputMethodCorrection.defaultExcludedApps)
    /// The user's exception words and the shipped reported words (ADR 0065).
    private(set) var ignoredWords: Set<String> = []
    /// Record undone corrections on this Mac (ADR 0065).
    private(set) var recordUndone = false
    /// The key that asks for a fix (ADR 0068).
    private(set) var shortcut = CorrectionShortcut.default
    private lazy var reportedWords: Set<String> = {
        let resource = InputMethodCorrection.reportedWordsResource
        guard let url = Bundle.main.url(forResource: resource.name, withExtension: resource.extension, subdirectory: resource.subdirectory),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(InputMethodCorrection.reportedWords(from: text))
    }()
    /// Raw opt-in host-test override from this input method's own preferences.
    private var testOverride: Any?
    private var started = false

    /// The route for a client. The override's expiry is checked on every call.
    func mode(for clientID: String?) -> CorrectionMode? {
        CorrectionRouting.mode(clientID: clientID, settingsMode: mode, excludedApps: excludedApps,
                               testOverride: CorrectionRouting.testOverride(from: testOverride, now: Date()))
    }

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed), name: Notification.Name(InputMethodCorrection.settingsChanged),
            object: nil, suspensionBehavior: .deliverImmediately)
        read()
    }

    @objc private func changed() { read() }

    private func read() {
        let defaults = UserDefaults(suiteName: InputMethodCorrection.preferencesDomain)
        let values = InputMethodCorrection.read(mode: defaults?.object(forKey: InputMethodCorrection.Key.mode),
                                                excludedApps: defaults?.object(forKey: InputMethodCorrection.Key.excludedApps),
                                                ignoredWords: defaults?.object(forKey: InputMethodCorrection.Key.ignoredWords),
                                                recordUndone: defaults?.object(forKey: InputMethodCorrection.Key.recordUndone),
                                                shortcut: defaults?.object(forKey: InputMethodCorrection.Key.shortcut))
        mode = values.mode
        excludedApps = values.excludedApps
        ignoredWords = values.ignoredWords.union(reportedWords)
        recordUndone = values.recordUndone
        shortcut = values.shortcut
        UserDefaults.standard.synchronize()
        testOverride = UserDefaults.standard.object(forKey: CorrectionRouting.testOverrideKey)
        let override = CorrectionRouting.testOverride(from: testOverride, now: Date())
        // The mode and a count only; app IDs are the user's own list.
        SpikeLog.notice("correction settings mode=\(mode.rawValue) excludedApps=\(excludedApps.count) ignoredWords=\(ignoredWords.count) recordUndone=\(recordUndone) shortcut=\(shortcut.rawValue) testOverride=\(override?.rawValue ?? "none")")
    }
}
