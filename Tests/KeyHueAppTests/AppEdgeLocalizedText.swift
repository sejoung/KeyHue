import Foundation
import Testing

/// 앱 경계 테스트 공용 도우미.
///
/// 번역 번들 테스트(LocalizationBundleTests)가 전역 언어를 잠시 바꾸므로, 다른 스위트에서 `L(...)` 결과를
/// 그 순간의 언어 하나와 비교하면 병렬 실행에서 흔들린다. 지원하는 모든 언어(와 영어 원문 키) 중 하나인지로 비교한다.
enum AppEdgeText {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let languages = ["en", "ko", "ja"]

    static func strings(_ language: String) throws -> [String: String] {
        let url = repoRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// `L(key, arguments...)`가 어떤 언어에서든 돌려줄 수 있는 문자열.
    static func anyLanguage(_ key: String, _ arguments: CVarArg...) -> Set<String> {
        var result: Set<String> = [String(format: key, arguments: arguments)]
        for language in languages {
            if let value = (try? strings(language))?[key] {
                result.insert(String(format: value, arguments: arguments))
            }
        }
        return result
    }
}
