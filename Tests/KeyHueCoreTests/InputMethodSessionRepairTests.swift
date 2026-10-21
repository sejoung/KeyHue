import Testing
@testable import KeyHueCore

@MainActor
private final class RepairHarness {
    let scheduler = FakeScheduler()
    var canRepair = true
    var context: AnyHashable? = 101
    var pressResults: [Bool] = []
    var presses = 0
    var started = 0
    var sourceID: String? = InputMethodIntegration.hangulID
    var restored: [String] = []
    var restoresSuccessfully = true
    var outcomes: [InputMethodSessionRepair.Outcome] = []
    lazy var repair: InputMethodSessionRepair = {
        let repair = InputMethodSessionRepair(
            scheduler: scheduler,
            canRepair: { [unowned self] in self.canRepair },
            currentContext: { [unowned self] in self.context },
            pressShortcut: { [unowned self] in
                self.presses += 1
                return self.pressResults.isEmpty ? true : self.pressResults.removeFirst()
            },
            currentSourceID: { [unowned self] in self.sourceID },
            selectSource: { [unowned self] id in
                self.restored.append(id)
                if self.restoresSuccessfully { self.sourceID = id }
                return self.restoresSuccessfully
            })
        repair.onRepairStarted = { [unowned self] in self.started += 1 }
        repair.onFinished = { [unowned self] in self.outcomes.append($0) }
        return repair
    }()

    func selectHangul(from previous: String? = InputMethodIntegration.abcID) {
        repair.selected(sourceID: InputMethodIntegration.hangulID, previousID: previous)
    }

    /// The acknowledgement window plus both shortcut presses and the final check.
    func runRepair() {
        scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        scheduler.advance(by: InputMethodSessionRepair.pressInterval)
    }
}

@MainActor
@Suite("Input method session repair")
struct InputMethodSessionRepairTests {
    @Test func acknowledgementWithinTheWindowNeedsNoShortcut() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: 0.1)
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes == [.acknowledged])
    }

    @Test func missingAcknowledgementPressesThePreviousSourceShortcutTwice() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        // The first press leaves the target; the second returns to it inside the client.
        #expect(h.presses == 1)
        #expect(h.started == 1)
        #expect(h.repair.isRepairing)
        h.scheduler.advance(by: InputMethodSessionRepair.pressInterval)
        #expect(h.presses == 2)
        #expect(h.repair.isRepairing)
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(!h.repair.isRepairing)
        #expect(h.outcomes == [.repaired])
    }

    @Test func appThatStillDoesNotAcknowledgeIsNotRepairedAgain() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.outcomes == [.unrepaired])
        // An app without a text input context must not flash the shortcut on every switch.
        h.selectHangul()
        h.scheduler.advance(by: 1)
        #expect(h.presses == 2)
        // Another app is still repaired.
        h.context = 202
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 3)
    }

    /// Toggling and typing at once used to cancel the repair, and the window kept
    /// typing raw ASCII under a Hangul menu bar until the app was switched (ADR 0070).
    /// The exclusion is not for good: one silence (a slow or outdated server) must
    /// not turn the repair off for that app until KeyHue restarts (ADR 0070).
    @Test func unrepairedAppIsTriedAgainAfterTheRetryInterval() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.outcomes == [.unrepaired])
        h.scheduler.advance(by: InputMethodSessionRepair.unrepairedRetryInterval)
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 3)
    }

    @Test func acknowledgementFromTheExcludedAppLiftsTheExclusion() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        // Later, e.g. after an app switch, a session of that app answers.
        h.repair.acknowledged(modeID: InputMethodIntegration.latinID)
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 3)
    }

    @Test func forgettingUnrepairedAppsTriesThemAgain() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        h.repair.forgetUnrepairedApps()
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 3)
    }

    /// An older exclusion's expiry must not lift a newer exclusion of the same app.
    @Test func reExclusionOutlivesTheEarlierExpiry() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        h.repair.forgetUnrepairedApps()
        h.scheduler.advance(by: 100)
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.outcomes == [.unrepaired, .unrepaired])
        // The first exclusion would have expired here; the second still holds.
        h.scheduler.advance(by: InputMethodSessionRepair.unrepairedRetryInterval - 100)
        h.selectHangul()
        h.scheduler.advance(by: 1)
        #expect(h.presses == 4)
    }

    @Test func userInteractionPostponesTheRepairUntilAPause() {
        let h = RepairHarness()
        h.selectHangul()
        for _ in 0..<4 {
            h.scheduler.advance(by: 0.1)
            h.repair.interaction()
        }
        // Never pressed between keys.
        #expect(h.presses == 0)
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout - 0.01)
        #expect(h.presses == 0)
        h.scheduler.advance(by: 0.01)
        #expect(h.presses == 1)
    }

    @Test func acknowledgementWhileTypingStillNeedsNoShortcut() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: 0.1)
        h.repair.interaction()
        h.scheduler.advance(by: 0.2)
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes == [.acknowledged])
    }

    @Test func interactionWithoutAPendingSelectionDoesNothing() {
        let h = RepairHarness()
        h.repair.interaction()
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes.isEmpty)
    }

    @Test func frontAppChangeWhileTypingSkips() {
        let h = RepairHarness()
        h.selectHangul()
        h.repair.interaction()
        h.context = 202
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes == [.skipped])
    }

    @Test func interactionDuringTheRepairDoesNotStrandTheIntermediateSource() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        h.repair.interaction()
        h.scheduler.advance(by: InputMethodSessionRepair.pressInterval)
        #expect(h.presses == 2)
    }

    @Test(arguments: [
        (InputMethodIntegration.abcID, InputMethodIntegration.hangulID),
        (InputMethodIntegration.systemHangulID, InputMethodIntegration.abcID),
        (InputMethodIntegration.hangulID, InputMethodIntegration.hangulID),
        (InputMethodIntegration.latinID, InputMethodIntegration.latinID)
    ])
    func onlyAChangeIntoAKeyHueModeIsWatched(_ target: String, _ previous: String) {
        let h = RepairHarness()
        h.repair.selected(sourceID: target, previousID: previous)
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes.isEmpty)
    }

    @Test func latinModeIsRepairedLikeHangul() {
        let h = RepairHarness()
        h.repair.selected(sourceID: InputMethodIntegration.latinID, previousID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 1)
    }

    @Test func unavailableShortcutSkipsWithoutPressing() {
        let h = RepairHarness()
        h.canRepair = false
        h.selectHangul()
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes == [.skipped])
        // Skipping is not a failed repair: the app is tried again later.
        h.canRepair = true
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 1)
    }

    @Test func frontAppChangeBeforeTheWindowEndsSkips() {
        let h = RepairHarness()
        h.selectHangul()
        h.context = 202
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes == [.skipped])
    }

    @Test func missingFrontAppIsNotWatched() {
        let h = RepairHarness()
        h.context = nil
        h.selectHangul()
        h.scheduler.advance(by: 1)
        #expect(h.presses == 0)
        #expect(h.outcomes.isEmpty)
    }

    @Test func newerSelectionReplacesTheWaitingOne() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: 0.2)
        h.repair.selected(sourceID: InputMethodIntegration.latinID, previousID: InputMethodIntegration.hangulID)
        // The old window ends here; only the new selection's window may press.
        h.scheduler.advance(by: 0.1)
        #expect(h.presses == 0)
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        // The new window started at 0.2 and ends now, before its second press.
        h.scheduler.advance(by: 0.2 + InputMethodSessionRepair.acknowledgementTimeout - 0.3)
        #expect(h.presses == 1)
    }

    @Test func acknowledgementOfAnotherModeDoesNotSatisfyTheTarget() {
        let h = RepairHarness()
        h.selectHangul()
        h.repair.acknowledged(modeID: InputMethodIntegration.latinID)
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.presses == 1)
    }

    @Test func failedFirstPressNeverSendsTheSecond() {
        let h = RepairHarness()
        h.pressResults = [false]
        h.selectHangul()
        h.runRepair()
        h.scheduler.advance(by: 1)
        #expect(h.presses == 1)
        #expect(!h.repair.isRepairing)
        #expect(h.outcomes == [.skipped])
    }

    @Test func selectionsDuringTheRepairAreIgnored() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        h.repair.selected(sourceID: InputMethodIntegration.latinID, previousID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: InputMethodSessionRepair.pressInterval)
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: 1)
        #expect(h.presses == 2)
        #expect(h.outcomes == [.repaired])
    }

    @Test func lateAcknowledgementWithoutAPendingSelectionIsIgnored() {
        let h = RepairHarness()
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: 1)
        #expect(h.outcomes.isEmpty)
    }

    /// KakaoTalk's delayed source restoration changed shortcut history and the
    /// Hangul repair ended on ABC. Never leave that intermediate source selected.
    @Test(arguments: [InputMethodIntegration.hangulID, InputMethodIntegration.latinID])
    func shortcutsEndingOnABCReselectTheTargetAndWaitForItsSession(_ target: String) {
        let h = RepairHarness()
        h.repair.selected(sourceID: target, previousID: InputMethodIntegration.abcID)
        h.runRepair()
        h.repair.acknowledged(modeID: target)
        h.sourceID = InputMethodIntegration.abcID
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.restored == [target])
        #expect(h.repair.isRepairing)
        #expect(h.outcomes.isEmpty)
        h.repair.acknowledged(modeID: target)
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        #expect(h.outcomes == [.repaired])
    }

    @Test func acknowledgementBeforeTargetRestorationDoesNotConfirmTheNewSelection() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.sourceID = InputMethodIntegration.latinID
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout * 2)
        #expect(h.sourceID == InputMethodIntegration.hangulID)
        #expect(h.outcomes == [.unrepaired])
    }

    @Test func overwrittenRestorationIsNotRetriedForeverOrReportedAsRepaired() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.sourceID = InputMethodIntegration.abcID
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.sourceID = InputMethodIntegration.abcID
        h.scheduler.advance(by: 1)
        #expect(h.restored.count == 1)
        #expect(h.outcomes == [.unrepaired])
    }

    @Test func failedTargetRestorationEndsUnrepaired() {
        let h = RepairHarness()
        h.restoresSuccessfully = false
        h.selectHangul()
        h.runRepair()
        h.sourceID = InputMethodIntegration.abcID
        h.scheduler.advance(by: 1)
        #expect(h.restored == [InputMethodIntegration.hangulID])
        #expect(h.outcomes == [.unrepaired])
    }

    @Test func appChangeBetweenPressesDoesNotSendAShortcutIntoTheNewApp() {
        let h = RepairHarness()
        h.selectHangul()
        h.scheduler.advance(by: InputMethodSessionRepair.acknowledgementTimeout)
        h.context = 202
        h.scheduler.advance(by: 1)
        #expect(h.presses == 1)
        #expect(h.restored.isEmpty)
        #expect(h.outcomes == [.skipped])
    }

    @Test func appChangeBeforeVerificationDoesNotRestoreIntoTheNewApp() {
        let h = RepairHarness()
        h.selectHangul()
        h.runRepair()
        h.context = 202
        h.sourceID = InputMethodIntegration.abcID
        h.scheduler.advance(by: 1)
        #expect(h.restored.isEmpty)
        #expect(h.outcomes == [.skipped])
    }

    @Test func acknowledgementAfterAppChangeCannotConfirmTheOldSelection() {
        let h = RepairHarness()
        h.selectHangul()
        h.context = 202
        h.repair.acknowledged(modeID: InputMethodIntegration.hangulID)
        h.scheduler.advance(by: 1)
        #expect(h.outcomes == [.skipped])
        #expect(h.presses == 0)
    }
}
