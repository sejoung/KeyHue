import AppKit
import Foundation
import KeyHueCore
import Testing
@testable import KeyHueApp

@MainActor
@Suite("Status menu titles edge cases")
struct AppEdgeStatusMenuTitleTests {
    @Test func switchBehaviorTitlesAreDistinctAndOnlyTheSwitchTitleNamesTheTarget() {
        let name = "ZZ-Target-Name"
        let titles = SwitchBehavior.allCases.map { StatusBarController.title(for: $0, defaultName: name) }
        #expect(Set(titles).count == SwitchBehavior.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(StatusBarController.title(for: .switchToDefault, defaultName: name).contains(name))
        #expect(!StatusBarController.title(for: .keep, defaultName: name).contains(name))
        #expect(!StatusBarController.title(for: .restoreLast, defaultName: name).contains(name))
    }

    @Test(arguments: ["", "%@", "100% ABC", "한글 · 日本語"])
    func unusualSourceNamesAreInsertedLiterally(_ name: String) {
        // 입력 소스 이름은 서식 문자열로 해석되지 않는다(이름에 %가 있어도 깨지지 않는다).
        let title = StatusBarController.title(for: .switchToDefault, defaultName: name)
        #expect(AppEdgeText.anyLanguage("Switch to %@", name).contains(title))
    }

    @Test func barPositionTitlesAreDistinct() {
        let titles = BarPosition.allCases.map(StatusBarController.title(for:))
        #expect(Set(titles).count == BarPosition.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test func stateNamesAreNeverEmpty() {
        let unnamed = InputSourceInfo(id: "com.example.unnamed", localizedName: "", languages: [], isASCIICapable: false)
        #expect(InputState.source(unnamed).displayName == "com.example.unnamed")
        #expect(InputState.source(.korean2Set).displayName == "2-Set Korean")
        #expect(!InputState.capsLock.displayName.isEmpty)
        #expect(!InputState.unknown.displayName.isEmpty)
        #expect(InputState.capsLock.displayName != InputState.unknown.displayName)
    }

    @Test func colorTargetsReadAndWriteTheirOwnColor() throws {
        var settings = KeyHueSettings()
        let red = try #require(RGBAColor(hex: "#FF0000"))
        let blue = try #require(RGBAColor(hex: "#0000FF"))
        ColorTarget.source(.hiragana).setColor(red, in: &settings)
        ColorTarget.capsLock.setColor(blue, in: &settings)
        #expect(ColorTarget.source(.hiragana).color(in: settings) == red)
        #expect(ColorTarget.capsLock.color(in: settings) == blue)
        #expect(ColorTarget.source(.abc).color(in: settings) != red) // 다른 소스에는 영향이 없다
        #expect(ColorTarget.source(.hiragana).title == "Hiragana")
        #expect(AppEdgeText.anyLanguage("Caps Lock").contains(ColorTarget.capsLock.title))
    }

    @Test func swatchIsASmallNonTemplateChip() {
        let swatch = StatusBarController.swatch(RGBAColor(hex: "#34C759")!)
        #expect(swatch.size == NSSize(width: 14, height: 14))
        #expect(!swatch.isTemplate) // template이면 메뉴가 색을 지워 버린다
    }
}

@Suite("Diagnostic log edge cases")
struct AppEdgeLogTests {
    @Test func testsNeverWriteTheUserLogFile() {
        // 설치된 KeyHue(번들 ID)로 실행될 때만 파일에 쓴다(ADR 0036). 테스트 실행기는 사용자 로그를 채우지 않는다.
        #expect(Bundle.main.bundleIdentifier != "io.github.sejoung.keyhue")
        #expect(Log.file == nil)
        Log.app.notice("AppEdgeLogTests notice") // 파일이 없어도 통합 로그로만 남고 멈추지 않는다
        Log.app.error("AppEdgeLogTests error")
    }

    @Test func logFileLivesInTheUserLogsFolder() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KeyHue/KeyHue.log")
        #expect(Log.fileURL.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test func categoriesAreDistinct() {
        let categories = [Log.app, .state, .accessibility, .keyboard, .inputSource, .loginItem].map(\.category)
        #expect(Set(categories).count == categories.count)
        #expect(Log.subsystem == "KeyHue")
    }
}

@Suite("Localization format safety")
struct AppEdgeLocalizationFormatTests {
    /// %@ 외의 % 서식(%d, %1$@, 짝 없는 %)은 String(format:)에서 인자와 어긋나거나 깨진다.
    /// Core 번역 테스트는 %@ 개수만 비교하므로 "100%" 같은 문자를 따로 확인한다.
    @Test func everyPercentSignIsAnObjectPlaceholder() throws {
        for language in AppEdgeText.languages {
            for (key, value) in try AppEdgeText.strings(language) {
                for text in [key, value] {
                    let stripped = text.replacingOccurrences(of: "%@", with: "")
                    #expect(!stripped.contains("%"), "\(language): \(key) → \(value)")
                }
            }
        }
    }

    @Test func translationsAreNotBlank() throws {
        for language in AppEdgeText.languages {
            for (key, value) in try AppEdgeText.strings(language) {
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): \(key)")
            }
        }
    }

    @Test func placeholdersFormatInEveryLanguage() throws {
        for language in AppEdgeText.languages {
            for (key, value) in try AppEdgeText.strings(language) where key.contains("%@") {
                let count = key.components(separatedBy: "%@").count - 1
                let arguments: [CVarArg] = (0..<count).map { "ARG\($0)" }
                let formatted = String(format: value, arguments: arguments)
                #expect(!formatted.contains("%@"), "\(language): \(key)")
                for argument in 0..<count {
                    #expect(formatted.contains("ARG\(argument)"), "\(language): \(key) lost argument \(argument)")
                }
            }
        }
    }
}
