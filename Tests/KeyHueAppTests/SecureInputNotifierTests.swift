import AppKit
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
private final class NotifierHarness {
    let scheduler = FakeScheduler()
    var sourceID: String? = InputSourceInfo.abc.id
    var integrated = true
    var front: AppFocusMonitor.ActiveApp? = .init(bundleID: "com.tinyspeck.slackmacgap", pid: 1212)
    var holder: SecureInputHolder? = SecureInputHolder(pid: 1214, bundleID: "com.google.Chrome", name: "Google Chrome")
    var now: TimeInterval = 0
    var shown: [(String, String)] = []
    lazy var notifier = SecureInputNotifier(
        scheduler: scheduler,
        currentSourceID: { [unowned self] in self.sourceID },
        integrated: { [unowned self] in self.integrated },
        front: { [unowned self] in self.front },
        holder: { [unowned self] in self.holder },
        now: { [unowned self] in self.now },
        show: { [unowned self] title, caption in self.shown.append((title, caption)) }
    )
}

@MainActor
@Suite("Secure input notifier")
struct SecureInputNotifierTests {
    /// 2026-11-18 13:04:49: Slack in front, Chrome holding secure input, ABC put back
    /// three times within 30 ms. One notice naming Chrome once the changes settle.
    @Test func burstOfOverwritesShowsOneNoticeNamingTheHolder() {
        let h = NotifierHarness()
        h.notifier.check()
        h.scheduler.advance(by: 0.01)
        h.notifier.check()
        h.scheduler.advance(by: 0.01)
        h.notifier.check()
        #expect(h.shown.isEmpty)
        h.scheduler.advance(by: SecureInputNoticePolicy.settleDelay)
        #expect(h.shown.count == 1)
        #expect(h.shown.first?.0.contains("Google Chrome") == true)
        #expect(h.shown.first?.1.contains("Google Chrome") == true)
        h.notifier.check()
        h.scheduler.advance(by: 1)
        #expect(h.shown.count == 1)
    }

    @Test func passwordFieldInTheFrontAppIsNotAnnounced() {
        let h = NotifierHarness()
        h.front = .init(bundleID: "com.google.Chrome", pid: 1214)
        h.notifier.check()
        h.scheduler.advance(by: 1)
        #expect(h.shown.isEmpty)
    }

    /// Secure input ended and came back later: announced again after the interval.
    @Test func endedHoldIsAnnouncedAgainLater() {
        let h = NotifierHarness()
        h.notifier.check()
        h.scheduler.advance(by: 1)
        let holder = h.holder
        h.holder = nil
        h.notifier.check()
        h.scheduler.advance(by: 1)
        h.holder = holder
        h.now = SecureInputNoticePolicy.minimumInterval + 5
        h.notifier.check()
        h.scheduler.advance(by: 1)
        #expect(h.shown.count == 2)
    }
}
