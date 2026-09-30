import Foundation
import KeyHueCore
import os

/// UI 문자열. 키는 영어 원문이고 번역은 `Contents/Resources/<lang>.lproj/Localizable.strings`에 둔다(ADR 0016).
/// 번들 없이 실행하면(`swift run`) 키(영어)가 그대로 나온다.
func L(_ key: String) -> String {
    Localization.bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
}

/// `%@`, `%d` 등을 포함한 키.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

/// 앱 안에서 고른 UI 언어. OS 언어와 다르게 쓸 수 있다(예: 한국어 OS에서 영어 UI).
enum Localization {
    private static let current = OSAllocatedUnfairLock<Bundle?>(initialState: translationBundle(.en, in: .main))

    static var bundle: Bundle? {
        current.withLock { $0 }
    }

    /// 지원하는 시스템 언어가 없으면 영어. 번역 폴더가 없으면 영어 번들 → 영어 원문 키 순으로 대체한다.
    /// base와 preferredLanguages는 테스트에서도 실제 번역 선택을 검증할 수 있게 주입한다.
    static func apply(
        _ language: AppLanguage,
        in base: Bundle = .main,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        let resolved = language.resolved(preferredLanguages: preferredLanguages)
        let bundle = translationBundle(resolved, in: base) ?? translationBundle(.en, in: base)
        current.withLock { $0 = bundle }
    }

    private static func translationBundle(_ language: AppLanguage, in base: Bundle) -> Bundle? {
        base.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}
