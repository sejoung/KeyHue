import Foundation
import KeyHueCore
import os

/// UI 문자열. 키는 영어 원문이고 번역은 `Contents/Resources/<lang>.lproj/Localizable.strings`에 둔다(ADR 0016).
/// 번들 없이 실행하면(`swift run`) 키(영어)가 그대로 나온다.
func L(_ key: String) -> String {
    Localization.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// `%@`, `%d` 등을 포함한 키.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

/// 앱 안에서 고른 UI 언어. OS 언어와 다르게 쓸 수 있다(예: 한국어 OS에서 영어 UI).
enum Localization {
    private static let current = OSAllocatedUnfairLock<Bundle>(initialState: .main)

    static var bundle: Bundle {
        current.withLock { $0 }
    }

    /// `.system`이면 Bundle.main(OS 언어 우선순위), 아니면 해당 `.lproj` 번들을 쓴다.
    /// 번역 폴더가 없으면(번들 없이 실행) Bundle.main으로 돌아간다.
    static func apply(_ language: AppLanguage) {
        let bundle = language.lprojName
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:)) ?? .main
        current.withLock { $0 = bundle }
    }
}
