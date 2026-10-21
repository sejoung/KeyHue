import Testing
@testable import KeyHueCore

@MainActor
@Suite("Routing pauses preserve the user's preference")
struct InputMethodRoutingPauseTests {
    private func overwrittenRoute() -> IntegrationHarness {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        h.observe(.abc)
        return h
    }

    /// Chrome on October 19 and Slack on October 20: TIS accepted both
    /// selections, then restored ABC within 3–15 ms. The saved option stayed OFF.
    @Test(arguments: [
        (InputSourceInfo.keyHueHangul, InputSourceInfo.abc),
        (.keyHueLatin, .abc), (.keyHueHangul, .korean2Set), (.keyHueLatin, .korean2Set)
    ])
    func overwritePausesWithoutTurningOffRouting(_ leaving: InputSourceInfo, _ detour: InputSourceInfo) {
        let h = IntegrationHarness()
        h.router.reset(current: leaving)
        h.observe(detour)
        h.scheduler.advance(by: 0)
        h.observe(detour)
        for _ in 0..<4 {
            h.observe(.keyHueHangul)
            h.observe(.keyHueLatin)
            h.observe(detour)
            h.scheduler.advance(by: 1)
        }
        #expect(h.routingEnabled)
        #expect(h.suspensions == 1)
        #expect(h.switcher.performed.count == 2)
        #expect(!h.router.isPending)
    }

    @Test func failedSelectionPausesWithoutRetryingOrTurningOffRouting() {
        let h = IntegrationHarness()
        h.switcher.shouldSucceed = false
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        h.observe(.keyHueLatin)
        h.observe(.abc)
        h.scheduler.advance(by: 60)
        #expect(h.routingEnabled)
        #expect(h.suspensions == 1)
        #expect(h.switcher.performed.count == 2)
    }

    @Test func typingDoesNotResumeOrChangeModeMidWord() {
        let h = overwrittenRoute()
        h.router.interaction(isTyping: true)
        h.observe(.keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 60)
        #expect(h.routingEnabled)
        #expect(h.switcher.currentSource == .abc)
        #expect(h.switcher.performed.count == 2)
    }

    @Test func freshShortcutOrClickAllowsTheNextRouteWithoutSelectingImmediately() {
        let h = overwrittenRoute()
        h.router.interaction(isTyping: false)
        h.scheduler.advance(by: 60)
        #expect(h.switcher.performed.count == 2)
        h.observe(.keyHueLatin)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .keyHueHangul)
        #expect(h.switcher.performed.count == 4)
        #expect(h.suspensions == 1)
        #expect(h.routingEnabled)
    }

    @Test func repeatedOverwritesStayBoundedOnEachNewAttempt() {
        let h = overwrittenRoute()
        for _ in 0..<3 {
            h.router.interaction(isTyping: false)
            h.observe(.keyHueLatin)
            h.observe(.abc)
            h.scheduler.advance(by: 0)
            h.observe(.abc)
            h.scheduler.advance(by: 60)
        }
        #expect(h.routingEnabled)
        #expect(h.suspensions == 4)
        #expect(h.switcher.performed.count == 8)
    }

    @Test func contextResetResumesRouting() {
        let h = overwrittenRoute()
        h.router.reset(current: .keyHueLatin)
        h.observe(.abc)
        h.scheduler.advance(by: 0)
        #expect(h.switcher.currentSource == .keyHueHangul)
        #expect(h.switcher.performed.count == 4)
        #expect(h.routingEnabled)
    }

    @Test func contextResetWithABCDoesNotRetryTheOldFailure() {
        let h = overwrittenRoute()
        h.router.reset(current: .abc)
        h.observe(.abc)
        h.scheduler.advance(by: 60)
        #expect(h.switcher.performed.count == 2)
        #expect(h.routingEnabled)
    }

    @Test func resumingStillHonorsTheUserTurningRoutingOff() {
        let h = overwrittenRoute()
        h.routingEnabled = false
        h.router.interaction(isTyping: false)
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(!h.routingEnabled)
        #expect(h.switcher.performed.count == 2)
    }

    @Test func resumingStillHonorsSecureInputAndMissingModes() {
        let h = overwrittenRoute()
        h.systemHolds = true
        h.router.interaction(isTyping: false)
        h.observe(.keyHueLatin)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.count == 2)
        h.systemHolds = false
        h.switcher.known.removeAll { $0.id == InputMethodIntegration.latinID }
        h.router.reset(current: .keyHueHangul)
        h.observe(.abc)
        h.scheduler.advance(by: 1)
        #expect(h.switcher.performed.count == 2)
        #expect(h.routingEnabled)
    }

    @Test func failedSystemDetourCleanupAlsoPausesWithoutChangingThePreference() {
        let h = IntegrationHarness()
        h.router.reset(current: .keyHueHangul)
        h.systemHolds = true
        h.observe(.abc)
        h.systemHolds = false
        h.switcher.shouldSucceed = false
        h.observe(.keyHueHangul)
        h.scheduler.advance(by: 0)
        h.observe(.abc)
        h.observe(.keyHueHangul)
        h.scheduler.advance(by: 60)
        #expect(h.routingEnabled)
        #expect(h.suspensions == 1)
        #expect(h.switcher.performed.count == 2)
    }
}
