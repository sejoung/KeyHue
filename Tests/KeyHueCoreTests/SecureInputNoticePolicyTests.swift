import Foundation
import Testing
@testable import KeyHueCore

@Suite("Secure input notice")
struct SecureInputNoticePolicyTests {
    /// 2026-11-18 13:04:49: Chrome (1214) held secure input, Slack (1212) was in front on ABC.
    private static let chromeBehindSlack = SecureInputNoticePolicy.Situation(
        integrated: true, currentIsDetour: true, holderPID: 1214, frontPID: 1212, frontIsLoginWindow: false)

    @Test func anotherAppHoldingSecureInputIsAnnouncedOnce() {
        var policy = SecureInputNoticePolicy()
        #expect(show(&policy, Self.chromeBehindSlack, 0))
        #expect(!show(&policy, Self.chromeBehindSlack, 1))
        #expect(!show(&policy, Self.chromeBehindSlack, 500)) // the same hold, still on
    }

    @Test func noNoticeWhenTheFrontAppHoldsItOrNothingIsBlocked() {
        var situation = Self.chromeBehindSlack
        situation.frontPID = 1214 // a password field in the front app selects ABC itself
        #expect(!SecureInputNoticePolicy.blocksKeyHue(situation))
        situation = Self.chromeBehindSlack
        situation.frontIsLoginWindow = true
        #expect(!SecureInputNoticePolicy.blocksKeyHue(situation))
        situation = Self.chromeBehindSlack
        situation.holderPID = nil
        #expect(!SecureInputNoticePolicy.blocksKeyHue(situation))
        situation = Self.chromeBehindSlack
        situation.currentIsDetour = false // a KeyHue mode is selected: nothing is blocked
        #expect(!SecureInputNoticePolicy.blocksKeyHue(situation))
        situation = Self.chromeBehindSlack
        situation.integrated = false // without KeyHue's modes ABC is the user's own source
        #expect(!SecureInputNoticePolicy.blocksKeyHue(situation))
        var policy = SecureInputNoticePolicy()
        #expect(!show(&policy, situation, 0))
    }

    /// 2026-11-12 17:09–17:13: Chrome held secure input again on every switch back to Slack.
    @Test func aNewHoldIsAnnouncedAgainOnlyAfterTheMinimumInterval() {
        var policy = SecureInputNoticePolicy()
        #expect(show(&policy, Self.chromeBehindSlack, 0))
        policy.secureInputEnded()
        #expect(!show(&policy, Self.chromeBehindSlack, 10))
        #expect(show(&policy, Self.chromeBehindSlack, SecureInputNoticePolicy.minimumInterval + 1))
    }

    @Test func anotherHolderIsAnnouncedAfterTheInterval() {
        var policy = SecureInputNoticePolicy()
        #expect(show(&policy, Self.chromeBehindSlack, 0))
        var other = Self.chromeBehindSlack
        other.holderPID = 4242
        #expect(!show(&policy, other, 5))
        #expect(show(&policy, other, 40))
    }
}

private func show(_ policy: inout SecureInputNoticePolicy, _ situation: SecureInputNoticePolicy.Situation, _ now: TimeInterval) -> Bool {
    policy.shouldShow(situation, now: now)
}
