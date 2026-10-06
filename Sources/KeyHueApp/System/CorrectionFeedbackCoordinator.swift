import AppKit
import KeyHueCore

/// Connects input method feedback notifications to the utility's local feedback store.
/// Presentation stays with AppDelegate, which owns the HUD and active-screen UI.
@MainActor
final class CorrectionFeedbackCoordinator {
    private let store: CorrectionFeedbackStore
    private let settings: @MainActor () -> KeyHueSettings
    private let showNotice: @MainActor (String, String) -> Void
    private var isStarted = false

    init(
        store: CorrectionFeedbackStore,
        settings: @escaping @MainActor () -> KeyHueSettings,
        showNotice: @escaping @MainActor (String, String) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.showNotice = showNotice
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Recording may have been turned off while KeyHue was not running.
        if settings().recordUndoneCorrections {
            store.reloadUndone()
        } else {
            store.clearUndone()
        }

        // The observers live as long as the app; their tokens are not kept.
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name(CorrectionFailure.notification), object: nil, queue: .main
        ) { [weak self] note in
            guard let event = CorrectionFailureEvent(userInfo: note.userInfo) else { return }
            MainActor.assumeIsolated { self?.recordFailure(event) }
        }
        center.addObserver(
            forName: Notification.Name(UndoneCorrectionLog.changedNotification), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Turning recording off already deleted the file (SettingsModel.recordUndoneBinding).
                guard let self, self.settings().recordUndoneCorrections else { return }
                self.store.reloadUndone()
            }
        }
    }

    private func recordFailure(_ event: CorrectionFailureEvent) {
        let notice = store.recordFailure(event)
        Log.app.notice("word fixing failed app=\(event.app) reason=\(event.reason.rawValue) notice=\(String(describing: notice))")
        guard let text = CorrectionFeedbackStore.noticeText(
            notice,
            reason: event.reason,
            appName: CorrectionFeedbackStore.appName(for: event.app),
            isTerminal: InputMethodCorrection.terminalApps.contains(event.app)
        ) else { return }
        showNotice(text.title, text.caption)
    }
}
