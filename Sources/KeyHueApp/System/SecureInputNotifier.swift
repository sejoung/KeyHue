import AppKit
import KeyHueCore

/// Tells the user that another app's secure input keeps KeyHue's modes from being
/// selected (ADR 0095). Checked on source changes and app activation only: there is no
/// notification when secure input ends, and KeyHue does not poll.
@MainActor
final class SecureInputNotifier {
    private let scheduler: Scheduling
    private let currentSourceID: @MainActor () -> String?
    private let integrated: @MainActor () -> Bool
    private let front: @MainActor () -> AppFocusMonitor.ActiveApp?
    private let holder: @MainActor () -> SecureInputHolder?
    private let now: @MainActor () -> TimeInterval
    private let show: @MainActor (_ title: String, _ caption: String) -> Void
    private var policy = SecureInputNoticePolicy()
    private var generation = 0

    init(scheduler: Scheduling = MainQueueScheduler(),
         currentSourceID: @escaping @MainActor () -> String?,
         integrated: @escaping @MainActor () -> Bool,
         front: @escaping @MainActor () -> AppFocusMonitor.ActiveApp?,
         holder: @escaping @MainActor () -> SecureInputHolder? = { SecureInputHolder.current() },
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         show: @escaping @MainActor (_ title: String, _ caption: String) -> Void) {
        self.scheduler = scheduler
        self.currentSourceID = currentSourceID
        self.integrated = integrated
        self.front = front
        self.holder = holder
        self.now = now
        self.show = show
    }

    /// The selected source changed or another app came to the front. Waits for the
    /// burst of overwrites to settle, then checks what is selected.
    func check() {
        generation += 1
        let request = generation
        scheduler.schedule(after: SecureInputNoticePolicy.settleDelay) { [weak self] in
            guard let self, self.generation == request else { return }
            self.evaluate()
        }
    }

    private func evaluate() {
        guard let holder = holder() else {
            policy.secureInputEnded()
            return
        }
        let front = front()
        let situation = SecureInputNoticePolicy.Situation(
            integrated: integrated(),
            currentIsDetour: currentSourceID().map(InputMethodIntegration.detourIDs.contains) ?? false,
            holderPID: holder.pid, frontPID: front?.pid,
            frontIsLoginWindow: front?.bundleID == "com.apple.loginwindow")
        guard SecureInputNoticePolicy.blocksKeyHue(situation) else { return }
        let shown = policy.shouldShow(situation, now: now())
        Log.state.notice("secure input held by \(holder.description) keeps KeyHue modes off; front=\(front?.bundleID ?? "-") notice=\(shown ? "shown" : "skipped")")
        guard shown else { return }
        let name = holder.name ?? holder.bundleID ?? L("Another App")
        show(L("Secure Input in %@", name), L("Only macOS input sources work until it ends. Go back to %@ or close its password field.", name))
    }
}
