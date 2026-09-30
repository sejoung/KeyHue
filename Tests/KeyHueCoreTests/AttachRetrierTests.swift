import Foundation
import Testing
@testable import KeyHueCore

/// 막 실행된 앱에 AX로 붙기(ADR 0033). 실제 시간 대신 FakeScheduler로 흘린다.
@MainActor
@Suite("Attach retry")
struct AttachRetrierTests {
    @Test func readyTargetIsAttachedOnceWithoutWaiting() {
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var attempts: [Int] = []
        retrier.start(1) { attempts.append($0); return true }
        #expect(attempts == [1])
        #expect(retrier.pendingTarget == nil)
        #expect(clock.pendingCount == 0)
    }

    @Test func notReadyAtActivationIsRetriedShortlyAfter() {
        // 실측: 활성화 알림 직후에는 실패(-25204), 100 ms 뒤에는 성공
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var attempts = 0
        retrier.start(1) { _ in attempts += 1; return attempts > 1 }
        #expect(attempts == 1)
        #expect(retrier.pendingTarget == 1)
        clock.advance(by: 0.1)
        #expect(attempts == 2)
        #expect(retrier.pendingTarget == nil)
        clock.advance(by: 10)
        #expect(attempts == 2)
    }

    @Test func firstRetryComesWithinAQuarterSecond() {
        #expect(AttachRetrier<Int>.delays.first! <= 0.25)
    }

    @Test func givesUpAfterAFewSeconds() {
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var attempts = 0
        retrier.start(1) { _ in attempts += 1; return false }
        clock.advance(by: 60)
        #expect(attempts == 1 + AttachRetrier<Int>.delays.count)
        #expect(retrier.pendingTarget == nil)
        #expect(AttachRetrier<Int>.delays.reduce(0, +) <= 5)
    }

    @Test func cancelDropsPendingRetries() {
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var attempts = 0
        retrier.start(1) { _ in attempts += 1; return false }
        retrier.cancel()
        #expect(retrier.pendingTarget == nil)
        clock.advance(by: 60)
        #expect(attempts == 1)
    }

    @Test func newTargetReplacesOldRetries() {
        // 실행 중인 앱 A를 기다리는 사이 앱 B로 옮기면 A에는 다시 붙지 않는다
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var attempts: [Int] = []
        retrier.start(1) { attempts.append($0); return false }
        retrier.start(2) { attempts.append($0); return true }
        clock.advance(by: 60)
        #expect(attempts == [1, 2])
        #expect(retrier.pendingTarget == nil)
    }
}
