import Foundation
import Testing
@testable import KeyHueCore

/// Resources/<lang>.lproj/Localizable.strings가 코드와 어긋나지 않는지 확인한다(ADR 0016).
@Suite("Localization")
struct LocalizationTests {
    @Test(arguments: ["fr-FR", "de-DE", "zh-Hans", "es", "", "system"])
    func unsupportedSystemLanguageFallsBackToEnglish(_ tag: String) {
        #expect(AppLanguage.system.resolved(preferredLanguages: [tag]) == .en)
    }

    @Test func regionalTagsAndSystemLanguagePriority() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ko-KR"]) == .ko)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["JA_jp"]) == .ja)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "ja-JP", "ko-KR"]) == .ja)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "ko-KR"]) == .en)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .en)
    }

    @Test(arguments: [AppLanguage.en, .ko, .ja])
    func explicitAppLanguageOverridesPreferences(_ language: AppLanguage) {
        #expect(language.resolved(preferredLanguages: ["fr-FR", "ko-KR"]) == language)
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // KeyHueCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
    /// 앱에서 고를 수 있는 언어(AppLanguage)와 번역 폴더가 일치해야 한다.
    static let languages = AppLanguage.allCases.compactMap(\.lprojName)

    static func strings(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// 앱 소스에서 `L("...")`로 쓴 키.
    static func keysUsedInCode() throws -> Set<String> {
        let sources = root.appendingPathComponent("Sources/KeyHueApp")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let pattern = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(text[range].replacingOccurrences(of: #"\""#, with: "\""))
            }
        }
        return keys
    }

    @Test func everyKeyUsedInCodeIsTranslated() throws {
        let used = try Self.keysUsedInCode()
        #expect(used.count > 50)
        for language in Self.languages {
            let missing = used.subtracting(try Self.strings(language).keys)
            #expect(missing.isEmpty, "\(language) is missing: \(missing.sorted())")
        }
    }

    @Test func languagesHaveTheSameKeys() throws {
        let english = Set(try Self.strings("en").keys)
        for language in Self.languages.dropFirst() {
            #expect(Set(try Self.strings(language).keys) == english, "\(language) keys differ from en")
        }
    }

    @Test func formatSpecifiersMatch() throws {
        func specifiers(_ text: String) -> Int { text.components(separatedBy: "%@").count - 1 }
        for language in Self.languages {
            for (key, value) in try Self.strings(language) {
                #expect(specifiers(key) == specifiers(value), "\(language): \(key)")
            }
        }
    }

    @Test func everySelectableLanguageHasTranslations() throws {
        #expect(Self.languages == ["en", "ko", "ja"])
        for language in Self.languages {
            #expect(!(try Self.strings(language)).isEmpty, "\(language).lproj missing")
        }
        let info = try String(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        for language in Self.languages {
            #expect(info.contains("<string>\(language)</string>"), "CFBundleLocalizations missing \(language)")
        }
    }

    @Test func noUnusedKeys() throws {
        let used = try Self.keysUsedInCode()
        let unused = Set(try Self.strings("en").keys).subtracting(used)
        #expect(unused.isEmpty, "unused keys: \(unused.sorted())")
    }
}
