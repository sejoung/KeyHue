import Carbon
import KeyHueCore

struct InputSourceDiagnosticSnapshot: Codable {
    var enabledIDs: [String]
    var currentID: String?
}

/// Carbon TIS(Text Input Source) API 래퍼. 조회와 전환을 담당한다.
@MainActor
enum InputSourceController {
    static func current() -> InputSourceInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return info(for: source)
    }

    /// 전환 가능한(enabled + select capable) 키보드 Input Source 목록.
    static func selectableKeyboardSources() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ] as CFDictionary
        let configured = InputMethodSourcePreferences.shared.enabledIDs
        guard let list = TISCreateInputSourceList(filter, configured != nil)?.takeRetainedValue() else {
            return []
        }
        let sources = (list as NSArray).compactMap { $0 as! TISInputSource? }
        guard let configured else { return sources }
        return sources.filter { source in
            let id: String = property(source, kTISPropertyInputSourceID) ?? ""
            if InputMethodSourcePreferences.ownedIDs.contains(id) { return configured.contains(id) }
            return (property(source, kTISPropertyInputSourceIsEnabled) as NSNumber?)?.boolValue == true
        }
    }

    @discardableResult
    static func perform(_ action: InputSourceAction) -> Bool {
        switch action {
        case .none:
            return false
        case .selectDefault(let preferredID):
            return selectDefault(preferredID: preferredID)
        case .select(let sourceID):
            return select(sourceID: sourceID)
        }
    }

    /// 설정 화면/메뉴에 보여줄 켜져 있는 키보드 입력 소스(시스템 설정의 순서).
    static func enabledSources() -> [InputSourceInfo] {
        selectableKeyboardSources().map(info(for:))
    }

    /// 자동 전환의 실제 목표. 지정한 Source가 꺼져 있으면 자동 선택으로 대체한다.
    static func resolvedDefaultSource(preferredID: String?) -> InputSourceInfo? {
        DefaultInputSourcePicker.pick(from: enabledSources(), preferredID: preferredID)
    }

    @discardableResult
    static func selectDefault(preferredID: String?) -> Bool {
        let sources = selectableKeyboardSources()
        let infos = sources.map(info(for:))
        guard let target = DefaultInputSourcePicker.pick(from: infos, preferredID: preferredID) else {
            Log.inputSource.error("no default keyboard input source is enabled")
            return false
        }
        return select(sourceID: target.id)
    }

    @discardableResult
    static func select(sourceID: String) -> Bool {
        guard let source = selectableKeyboardSources().first(where: { info(for: $0).id == sourceID }) else {
            Log.inputSource.notice("input source \(sourceID) is no longer available")
            return false
        }
        return select(source, id: sourceID)
    }

    /// Only lifecycle operations use a fresh process. Normal switching stays native.
    static func selectFresh(sourceID: String, workerExecutable: URL? = Bundle.main.executableURL) -> Bool {
        guard let workerExecutable else { return false }
        let worker = Process()
        worker.executableURL = workerExecutable
        worker.arguments = ["--keyhue-select-input-source", sourceID]
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        do { try worker.run(); worker.waitUntilExit() } catch { return false }
        return worker.terminationStatus == 0
    }

    static func freshSnapshot(workerExecutable: URL? = Bundle.main.executableURL) -> InputSourceDiagnosticSnapshot? {
        guard let workerExecutable, workerExecutable.lastPathComponent == "KeyHue" else { return nil }
        let task = Process()
        let output = Pipe()
        task.executableURL = workerExecutable
        task.arguments = ["--keyhue-input-source-status"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run(); task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: output.fileHandleForReading.readDataToEndOfFile())
        } catch { return nil }
    }

    static func selectNative(sourceID: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return false }
        return select(source, id: sourceID)
    }

    static func nativeEnabledInputMethodIDs() -> [String] {
        let filter = [kTISPropertyBundleID as String: InputMethodManager.bundleID] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return sources.compactMap { source in
            guard (property(source, kTISPropertyInputSourceIsSelectCapable) as NSNumber?)?.boolValue == true else { return nil }
            return property(source, kTISPropertyInputSourceID) as String?
        }
    }

    private static func select(_ source: TISInputSource, id: String) -> Bool {
        let status = TISSelectInputSource(source)
        if status != noErr {
            Log.inputSource.error("TISSelectInputSource(\(id)) failed: \(status)")
        }
        return status == noErr
    }

    static func info(for source: TISInputSource) -> InputSourceInfo {
        InputSourceInfo(
            id: property(source, kTISPropertyInputSourceID) ?? "",
            localizedName: property(source, kTISPropertyLocalizedName) ?? "",
            languages: property(source, kTISPropertyInputSourceLanguages) ?? [],
            isASCIICapable: (property(source, kTISPropertyInputSourceIsASCIICapable) as NSNumber?)?.boolValue ?? false
        )
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}
