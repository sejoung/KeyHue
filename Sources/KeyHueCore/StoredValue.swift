import Foundation

/// UserDefaults 값 해석. 유틸리티의 `SettingsStore`와 입력기가 읽는 `InputMethodCorrection`이 같은 규칙을 쓴다.
enum StoredValue {
    /// 켜기/끄기: 저장된 불리언·숫자, 또는 `defaults write`로 손으로 넣을 법한 글자(YES/NO, true/false, 1/0).
    static func bool(from raw: Any) -> Bool? {
        if let text = raw as? String {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        guard let number = raw as? NSNumber, !number.doubleValue.isNaN else { return nil }
        return number.boolValue
    }
}
