import Foundation

/// 같은 앱 안에서 "다른 창으로 옮겼는지"를 판단한다(ADR 0027).
///
/// 앱의 **메인 창**이 바뀔 때만 센다. 실측(테스트 앱)에서
/// - 창 전환과 탭 전환 모두 "메인 창 변경" 알림이 왔다(탭 전환은 "포커스 창 변경"이 오지 않는다).
/// - 떠 있는 패널·대화상자는 보통 메인 창이 되지 않으므로 자연스럽게 제외된다.
/// - 대화상자를 닫고 같은 창으로 돌아오면 같은 창이라 세지 않는다.
/// 창 식별자(ID)는 앱이 정한다(AX 요소를 CFEqual로 비교).
public struct WindowSwitchTracker<ID: Equatable> {
    private var current: ID?

    public init() {}

    /// 지금 알고 있는 메인 창(창별 기억에서 "지금 창"으로 쓴다).
    public var currentWindow: ID? { current }

    /// 앱이 바뀌면 기준을 새 앱의 현재 메인 창으로 다시 잡는다(앱 전환은 별도 옵션이 맡는다).
    public mutating func reset(to window: ID?) {
        current = window
    }

    /// 메인 창이 바뀌었다는 알림. 알고 있던 **다른** 창에서 옮겨 온 경우에만 true.
    /// 기준이 없으면(앱 전환 직후 등) 기준만 잡고 false.
    public mutating func mainWindowChanged(to window: ID?) -> Bool {
        guard let window else { return false }
        defer { current = window }
        guard let previous = current else { return false }
        return previous != window
    }
}
