import Foundation

/// macOS "Capitalize words automatically" (Keyboard › Text Input › Edit…), a setting
/// for all apps (`NSAutomaticCapitalizationEnabled` in the global domain). With it on,
/// apps capitalize the first word of a sentence at Space. KeyHue English is typed as
/// is (ADR 0081), so the fix shortcut can read a capital the user did not type and
/// make a tense consonant (rk → Rk → 까). KeyHue only reads it and recommends turning
/// it off; it never changes it.
struct SystemAutoCapitalization {
    static let key = "NSAutomaticCapitalizationEnabled"

    /// 테스트에서는 임시 도메인을 쓴다.
    private let domain: CFString

    init(domain: CFString = kCFPreferencesAnyApplication) {
        self.domain = domain
    }

    /// 키가 없으면 macOS 기본값(켜짐)이다. `defaults write -g … 0`도 꺼짐으로 읽는다.
    var isOn: Bool {
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyValue(Self.key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return true
        }
        return (value as? NSNumber)?.boolValue != false
    }
}
