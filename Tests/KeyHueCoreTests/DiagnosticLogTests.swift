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

    // MARK: 엣지 케이스

    private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// 한 줄이 파일에서 차지하는 바이트 수(시각 형식은 길이가 고정이다).
    private func lineBytes(_ message: String, level: String = "notice", category: String = "Test") -> Int {
        let (probe, url) = makeFile()
        probe.write(message, level: level, category: category, date: fixedDate)
        probe.flush()
        return (try? Data(contentsOf: url).count) ?? 0
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func fillingExactlyToTheLimitDoesNotRotate() {
        // "넘으면" 돌린다: 딱 maxBytes가 되는 줄은 같은 파일에 쓴다
        let length = lineBytes("aaaa")
        let (file, url) = makeFile(maxBytes: length * 2, keep: 3)
        file.write("aaaa", level: "notice", category: "Test", date: fixedDate)
        file.write("bbbb", level: "notice", category: "Test", date: fixedDate)
        file.flush()
        #expect(size(url) == length * 2)
        #expect(!exists(file.allFiles[1]))

        file.write("cccc", level: "notice", category: "Test", date: fixedDate)
        file.flush()
        #expect(read(file.allFiles[1]).contains("aaaa") && read(file.allFiles[1]).contains("bbbb"))
        #expect(read(url).hasSuffix("cccc\n"))
        #expect(size(url) == length)
    }

    @Test func limitCountsBytesNotCharacters() {
        // 한글은 글자당 3바이트다. 글자 수로 세면 파일이 한도를 넘는다.
        let message = String(repeating: "한", count: 20)
        let length = lineBytes(message)
        let (file, url) = makeFile(maxBytes: length * 2 + 10, keep: 3)
        for _ in 0..<5 {
            file.write(message, level: "notice", category: "Test", date: fixedDate)
        }
        file.flush()
        for existing in file.allFiles {
            #expect(size(existing) <= length * 2 + 10)
            // 줄이 중간(UTF-8 경계)에서 잘리지 않는다
            let text = read(existing)
            #expect(!text.isEmpty)
            for line in text.split(separator: "\n") {
                #expect(line.hasSuffix("[Test] \(message)"))
            }
        }
        #expect(read(url).split(separator: "\n").count == 1)
    }

    @Test(arguments: [1, 0, -3])
    func keepingOneFileRotatesInPlace(_ keep: Int) {
        let (file, url) = makeFile(maxBytes: 100, keep: keep)
        #expect(file.allFiles == [url])
        for i in 0..<10 {
            file.write("line \(i) " + String(repeating: "z", count: 50), level: "notice", category: "Test")
        }
        file.flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        #expect(names == ["KeyHue.log"])
        #expect(read(url).contains("line 9 "))
        #expect(!read(url).contains("line 8 "))
    }

    @Test func reopeningAnAlmostFullFileRotatesBeforeExceedingTheLimit() {
        // 다시 실행해도 기존 파일 크기를 세어 한도를 지킨다
        let length = lineBytes("old")
        let (first, url) = makeFile(maxBytes: length * 2, keep: 2)
        first.write("old", level: "notice", category: "Test", date: fixedDate)
        first.write("old", level: "notice", category: "Test", date: fixedDate)
        first.flush()

        let second = RotatingLogFile(url: url, maxBytes: length * 2, keep: 2)
        second.write("new", level: "notice", category: "Test", date: fixedDate)
        second.flush()
        #expect(read(url).hasSuffix("new\n"))
        #expect(size(url) == lineBytes("new"))
        #expect(read(second.allFiles[1]).split(separator: "\n").count == 2)
    }

    @Test func missingRotatedFileDoesNotStopRotation() throws {
        // 사용자가 KeyHue.1.log만 지워도 계속 돌려 쓴다
        let (file, url) = makeFile(maxBytes: 150, keep: 3)
        for i in 0..<8 {
            file.write("first \(i) " + String(repeating: "x", count: 60), level: "notice", category: "Test")
        }
        file.flush()
        try FileManager.default.removeItem(at: file.allFiles[1])
        for i in 0..<8 {
            file.write("second \(i) " + String(repeating: "x", count: 60), level: "notice", category: "Test")
        }
        file.flush()
        #expect(read(url).contains("second 7 "))
        #expect(file.allFiles.allSatisfy(exists))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        #expect(names.count == 3)
    }

    @Test func unwritableFolderIsSkippedAndRecoveredLater() throws {
        // 폴더 자리에 파일이 있어 만들 수 없으면 조용히 건너뛰고, 원인이 사라지면 다음 줄부터 쓴다
        let (file, url) = makeFile()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: folder.path, contents: Data("blocker".utf8)))
        file.write("lost", level: "notice", category: "Test")
        file.flush()
        #expect(!exists(url))

        try FileManager.default.removeItem(at: folder)
        file.write("kept", level: "notice", category: "Test")
        file.flush()
        #expect(read(url).hasSuffix("[Test] kept\n"))
        #expect(!read(url).contains("lost"))
    }

    @Test func flushWithoutWritesCreatesNothing() {
        // "로그 파일 보기"는 파일이 없으면 폴더를 연다. 빈 파일을 미리 만들지 않는다.
        let (file, url) = makeFile()
        file.flush()
        #expect(!exists(url))
        #expect(!exists(url.deletingLastPathComponent()))
    }

    @Test func concurrentWritersKeepEveryLineWhole() {
        let (file, url) = makeFile(maxBytes: 1_000_000, keep: 2)
        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { i in
            file.write("message \(i) " + String(repeating: "가", count: 10), level: "notice", category: "Test")
        }
        file.flush()
        let lines = read(url).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == count)
        let numbers = Set(lines.compactMap { line -> Int? in
            guard let range = line.range(of: "[Test] message ") else { return nil }
            return Int(line[range.upperBound...].prefix { $0.isNumber })
        })
        #expect(numbers == Set(0..<count))
        #expect(lines.allSatisfy { $0.hasSuffix(String(repeating: "가", count: 10)) })
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

    @Test func everySettingIsNamedInDeclarationOrder() {
        // 새 설정의 타입을 logDescription이 다르게 적거나 빠뜨리면 여기서 잡힌다
        let lines = KeyHueSettings.everyOptionChanged.nonDefaultDescriptions
        #expect(lines.map { String($0.prefix { $0 != "=" }) } == KeyHueSettings.propertyNames)
        #expect(lines.contains("appLanguage=ja"))
        #expect(lines.contains("barOpacity=0.4"))
        #expect(lines.contains("showStateBar=false"))
        #expect(lines.contains("defaultSourceID=com.apple.keylayout.German"))
        #expect(lines.contains("capsLockColor=#112233"))
        #expect(lines.contains("sourceColors={com.apple.keylayout.ABC:#12345680}"))
    }

    @Test func colorMapsAreSortedByIDAndKeepAlpha() {
        var settings = KeyHueSettings()
        settings.sourceColors = [
            "z.layout": RGBAColor(hex: "#00FF00")!,
            "a.layout": RGBAColor(hex: "#FF000080")!,
            "m.layout": RGBAColor(hex: "#0000FF00")!
        ]
        #expect(settings.nonDefaultDescriptions == ["sourceColors={a.layout:#FF000080,m.layout:#0000FF00,z.layout:#00FF00}"])
    }

    @Test func changesBackToDefaultsAreDescribedToo() {
        let old = KeyHueSettings.everyOptionChanged
        let lines = KeyHueSettings.changeDescriptions(from: old, to: KeyHueSettings())
        #expect(lines.count == KeyHueSettings.propertyNames.count)
        #expect(lines.contains("barOpacity: 0.4 → 1.0"))
        #expect(lines.contains("sourceColors: {com.apple.keylayout.ABC:#12345680} → {}"))
        #expect(lines.contains("defaultSourceID: com.apple.keylayout.German → -"))
    }

    @Test func onlyTheChangedColorEntryMakesADifference() {
        var old = KeyHueSettings()
        old.sourceColors = ["a": RGBAColor(hex: "#111111")!, "b": RGBAColor(hex: "#222222")!]
        var new = old
        new.sourceColors["b"] = RGBAColor(hex: "#333333")!
        #expect(KeyHueSettings.changeDescriptions(from: old, to: new) == ["sourceColors: {a:#111111,b:#222222} → {a:#111111,b:#333333}"])
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
