import Foundation
import Testing
@testable import KeyHueCore

/// 진단 로그 파일과 설정 설명(ADR 0036).
@Suite("Diagnostic log file")
struct RotatingLogFileTests {
    private func makeFile(maxBytes: Int = 1_000_000, keep: Int = 3) -> (RotatingLogFile, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyHueTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("KeyHue.log")
        return (RotatingLogFile(url: url, maxBytes: maxBytes, keep: keep), url)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func writesTimestampLevelCategoryAndMessage() {
        let (file, url) = makeFile()
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 9, 30)
        (components.hour, components.minute, components.second, components.nanosecond) = (10, 12, 3, 123_000_000)
        let date = Calendar.current.date(from: components)!
        file.write("window switched within com.mitchellh.ghostty", level: "notice", category: "State", date: date)
        file.flush()
        #expect(read(url) == "2026-09-30 10:12:03.123 notice [State] window switched within com.mitchellh.ghostty\n")
    }

    @Test func createsTheFolderAndAppendsAcrossInstances() {
        // KeyHue를 다시 실행해도 이전 기록 뒤에 이어 쓴다
        let (first, url) = makeFile()
        first.write("one", level: "notice", category: "App")
        first.flush()
        let second = RotatingLogFile(url: url)
        second.write("two", level: "notice", category: "App")
        second.flush()
        let lines = read(url).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("[App] one"))
        #expect(lines[1].hasSuffix("[App] two"))
    }

    @Test func rotatesWhenFullAndKeepsOnlyRecentFiles() {
        let (file, url) = makeFile(maxBytes: 200, keep: 3)
        for i in 0..<20 {
            file.write("line \(i) " + String(repeating: "x", count: 40), level: "notice", category: "Test")
        }
        file.flush()
        let files = file.allFiles
        #expect(files.map(\.lastPathComponent) == ["KeyHue.log", "KeyHue.1.log", "KeyHue.2.log"])
        for existing in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.size] as? Int) ?? 0
            #expect(size > 0 && size <= 200)
        }
        // 가장 최근 줄은 현재 파일에, 가장 오래된 줄은 지워졌다
        #expect(read(url).contains("line 19 "))
        let everything = files.map(read).joined()
        #expect(!everything.contains("line 0 "))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        #expect(leftovers.count == 3)
    }

    @Test func aLineLongerThanTheLimitIsStillWritten() {
        let (file, url) = makeFile(maxBytes: 10, keep: 2)
        file.write(String(repeating: "y", count: 50), level: "error", category: "Test")
        file.flush()
        #expect(read(url).contains(String(repeating: "y", count: 50)))
    }
}

@Suite("Settings log description")
struct SettingsLogDescriptionTests {
    @Test func defaultSettingsHaveNothingToReport() {
        #expect(KeyHueSettings().nonDefaultDescriptions.isEmpty)
    }

    @Test func listsOnlyNonDefaultSettings() {
        var settings = KeyHueSettings()
        settings.onAppSwitch = .restoreLast
        settings.barHeight = 8
        settings.defaultSourceID = "com.apple.keylayout.ABC"
        #expect(settings.nonDefaultDescriptions == [
            "barHeight=8.0",
            "onAppSwitch=restoreLast",
            "defaultSourceID=com.apple.keylayout.ABC"
        ])
    }

    @Test func describesChangesWithOldAndNewValues() {
        let old = KeyHueSettings()
        var new = old
        new.onWindowSwitch = .restoreLast
        new.capsLockColor = RGBAColor(hex: "#112233")!
        new.sourceColors = ["com.apple.keylayout.ABC": RGBAColor(hex: "#0000FF")!]
        #expect(KeyHueSettings.changeDescriptions(from: old, to: new) == [
            "sourceColors: {} → {com.apple.keylayout.ABC:#0000FF}",
            "capsLockColor: \(old.capsLockColor.hexString) → #112233",
            "onWindowSwitch: keep → restoreLast"
        ])
        #expect(KeyHueSettings.changeDescriptions(from: new, to: new).isEmpty)
    }

    @Test func autoResetEventsReadShortInLogs() {
        #expect("\(AutoResetCoordinator.Event.switched(.select(sourceID: "com.apple.keylayout.ABC"), ok: true))" == "switched select(com.apple.keylayout.ABC) ok")
        #expect("\(AutoResetCoordinator.Event.switched(.selectDefault(preferredID: nil), ok: false))" == "switched default(auto) FAILED")
        #expect("\(AutoResetCoordinator.Event.retrying(.selectDefault(preferredID: "com.apple.keylayout.US")))" == "retrying default(com.apple.keylayout.US) (overwritten)")
        #expect("\(AutoResetCoordinator.Event.skipped(.none))" == "skipped none (already there)")
    }

    @Test func missingOptionalIsADash() {
        var settings = KeyHueSettings()
        settings.defaultSourceID = "com.apple.keylayout.US"
        #expect(KeyHueSettings.changeDescriptions(from: settings, to: KeyHueSettings()) == ["defaultSourceID: com.apple.keylayout.US → -"])
    }

    @Test func recreatesTheFileWhenTheLogFolderIsDeleted() throws {
        // 사용자가 ~/Library/Logs/KeyHue를 지워도 다음 줄부터 다시 남는다("로그 파일 보기"가 빈손이 되지 않게)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyHueLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RotatingLogFile(url: directory.appendingPathComponent("KeyHue.log"))
        log.write("one", level: "notice", category: "Test")
        log.flush()
        try FileManager.default.removeItem(at: directory)
        log.write("two", level: "notice", category: "Test")
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("two"))
        #expect(!text.contains("one"))
    }
}
