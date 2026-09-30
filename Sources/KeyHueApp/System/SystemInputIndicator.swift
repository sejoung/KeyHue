import Foundation

/// macOS가 입력 소스를 바꿀 때 커서 옆에 띄우는 표시(한/A 배지). macOS 14부터 기본으로 켜져 있다(ADR 0034).
///
/// 모든 앱에 적용되는 macOS 설정(전역 도메인의 `TSMLanguageIndicatorEnabled`, Apple 비공개 키)이다.
/// 그래서 KeyHue 설정에 따로 저장하지 않고 실제 값을 읽으며, 사용자가 설정 창에서 바꿀 때만 쓴다.
/// - 숨김: false를 쓴다.
/// - 다시 표시: 키를 지워 macOS 기본값으로 돌린다.
/// 실측: 이미 실행 중인 앱에도 바로 적용된다(다시 실행할 필요 없음).
struct SystemInputIndicator {
    static let key = "TSMLanguageIndicatorEnabled"

    /// 테스트에서는 임시 도메인을 쓴다.
    private let domain: CFString

    init(domain: CFString = kCFPreferencesAnyApplication) {
        self.domain = domain
    }

    /// 키가 없으면 macOS 기본값(표시)이다. `defaults write -g … -bool false`와 `… 0` 모두 숨김으로 읽는다.
    var isHidden: Bool {
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyValue(Self.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return false
        }
        return (value as? NSNumber)?.boolValue == false
    }

    func setHidden(_ hidden: Bool) {
        CFPreferencesSetValue(
            Self.key as CFString,
            hidden ? kCFBooleanFalse : nil,
            domain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
