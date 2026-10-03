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

    @Test func reportsGivingUpOnlyAfterTheLastRetry() {
        // 끝까지 실패한 것은 로그로 남긴다. 취소·대상 변경은 포기가 아니다
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var gaveUp: [Int] = []
        retrier.start(1, attempt: { _ in false }, onGiveUp: { gaveUp.append($0) })
        clock.advance(by: AttachRetrier<Int>.delays.dropLast().reduce(0, +))
        #expect(gaveUp.isEmpty)
        clock.advance(by: 60)
        #expect(gaveUp == [1])

        retrier.start(2, attempt: { _ in false }, onGiveUp: { gaveUp.append($0) })
        retrier.start(3, attempt: { _ in true }, onGiveUp: { gaveUp.append($0) })
        retrier.start(4, attempt: { _ in false }, onGiveUp: { gaveUp.append($0) })
        retrier.cancel()
        clock.advance(by: 60)
        #expect(gaveUp == [1])
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

    // MARK: 엣지 케이스

    @Test func retriesFollowTheDelayScheduleExactly() {
        // 실패한 시도 뒤에 다음 간격을 센다: 0, 0.1, 0.3, 0.7, 1.5, 3.0
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var attempts = 0
        retrier.start(1) { _ in attempts += 1; return false }
        for (index, delay) in AttachRetrier<Int>.delays.enumerated() {
            clock.advance(by: delay - 0.001)
            #expect(attempts == index + 1, "retry \(index + 1) came too early")
            clock.advance(by: 0.001)
            #expect(attempts == index + 2, "retry \(index + 1) did not come after \(delay)s")
        }
        #expect(clock.pendingCount == 0)
        #expect(retrier.pendingTarget == nil)
    }

    @Test func successOnTheLastRetryIsNotGivingUp() {
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        let total = 1 + AttachRetrier<Int>.delays.count
        var attempts = 0
        var gaveUp = 0
        retrier.start(1, attempt: { _ in attempts += 1; return attempts == total }, onGiveUp: { _ in gaveUp += 1 })
        clock.advance(by: 60)
        #expect(attempts == total)
        #expect(gaveUp == 0)
        #expect(retrier.pendingTarget == nil)
    }

    @Test func restartingTheSameTargetStartsAFreshSchedule() {
        // 같은 대상을 다시 시작하면 이전 예약은 버리고 처음부터 센다(같은 대상이라도 이전 예약이 끼어들지 않는다)
        let clock = FakeScheduler()
        let retrier = AttachRetrier<String>(scheduler: clock)
        var attempts = 0
        var gaveUp: [String] = []
        let attempt: @MainActor (String) -> Bool = { _ in attempts += 1; return false }
        retrier.start("app", attempt: attempt, onGiveUp: { gaveUp.append($0) })
        clock.advance(by: 0.3) // 처음 + 재시도 2번
        #expect(attempts == 3)
        retrier.start("app", attempt: attempt, onGiveUp: { gaveUp.append($0) })
        #expect(attempts == 4)
        clock.advance(by: 60)
        #expect(attempts == 4 + AttachRetrier<String>.delays.count)
        #expect(gaveUp == ["app"])
    }

    @Test func startingAgainAfterGivingUpTriesAgain() {
        // 포기한 뒤라도 다음 앱 활성화 때 다시 붙는다
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var ready = false
        var attempts = 0
        var gaveUp = 0
        retrier.start(1, attempt: { _ in attempts += 1; return ready }, onGiveUp: { _ in gaveUp += 1 })
        clock.advance(by: 60)
        #expect(gaveUp == 1)
        ready = true
        retrier.start(1, attempt: { _ in attempts += 1; return ready }, onGiveUp: { _ in gaveUp += 1 })
        #expect(attempts == 2 + AttachRetrier<Int>.delays.count)
        #expect(retrier.pendingTarget == nil)
        #expect(gaveUp == 1)
    }

    @Test func cancellingWithNothingPendingIsHarmless() {
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        retrier.cancel()
        retrier.cancel()
        var attempts = 0
        retrier.start(1) { _ in attempts += 1; return attempts > 1 }
        clock.advance(by: 0.1)
        #expect(attempts == 2)
    }

    @Test func pendingTargetIsClearedWhileAttempting() {
        // 시도하는 동안에는 "기다리는 중"이 아니다. 앱은 이 값으로 같은 대상에 다시 붙을지 정한다.
        let clock = FakeScheduler()
        let retrier = AttachRetrier<Int>(scheduler: clock)
        var seen: [Int?] = []
        retrier.start(1) { _ in seen.append(retrier.pendingTarget); return false }
        #expect(retrier.pendingTarget == 1)
        clock.advance(by: 0.1)
        #expect(seen == [nil, nil])
        #expect(retrier.pendingTarget == 1)
    }

    @Test func delaysGrow() {
        let delays = AttachRetrier<Int>.delays
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
    }
}
