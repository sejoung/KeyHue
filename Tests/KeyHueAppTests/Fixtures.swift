import KeyHueCore

/// 통합 테스트용 예시 입력 소스(Core 테스트의 것과 같다).
extension InputSourceInfo {
    static let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", localizedName: "ABC", languages: ["en"], isASCIICapable: true)
    static let korean2Set = InputSourceInfo(
        id: "com.apple.inputmethod.Korean.2SetKorean", localizedName: "2-Set Korean", languages: ["ko"], isASCIICapable: false
    )
    static let hiragana = InputSourceInfo(
        id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", localizedName: "Hiragana", languages: ["ja"], isASCIICapable: false
    )
}

import Foundation

/// 가짜 시간: advance(by:)로 흘린 만큼 예약된 작업을 순서대로 실행한다(Core 테스트의 것과 같다).
/// 실제 시간을 기다리는 테스트는 느린 CI 러너에서 흔들리므로 타이밍 테스트는 이것을 쓴다.
@MainActor
final class FakeScheduler: Scheduling {
    private var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, work: @MainActor () -> Void)] = []
    private var counter = 0

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        counter += 1
        pending.append((now + delay, counter, work))
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = pending.filter({ $0.at <= target + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = next.at
            next.work()
        }
        now = target
    }
}
