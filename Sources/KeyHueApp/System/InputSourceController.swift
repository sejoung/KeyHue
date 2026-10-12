import Carbon
import KeyHueCore

/// Carbon TIS(Text Input Source) API 래퍼. 조회와 전환을 담당한다.
@MainActor
enum InputSourceController {
    static func current() -> InputSourceInfo? {
        TISInputSource.current?.info
    }

    /// 전환 가능한(enabled + select capable) 키보드 Input Source 목록.
    static func selectableKeyboardSources() -> [TISInputSource] {
        let sources = TISInputSource.list([
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable: true
        ], includeAllInstalled: false)
        guard let configured = InputMethodSourcePreferences.shared.enabledIDs else { return sources }
        let parentEnabled = TISInputSource.list([kTISPropertyInputSourceID: InputMethodIntegration.bundleID], includeAllInstalled: false)
            .contains(where: \.isEnabled)
        return sources.filter { source in
            let id = source.id ?? ""
            if InputMethodIntegration.ownedIDs.contains(id) {
                return parentEnabled && configured.contains(id) && source.isEnabled
            }
            return source.isEnabled
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
        selectableKeyboardSources().map(\.info)
    }

    /// 자동 전환의 실제 목표. 지정한 Source가 꺼져 있으면 자동 선택으로 대체한다.
    static func resolvedDefaultSource(preferredID: String?) -> InputSourceInfo? {
        DefaultInputSourcePicker.pick(from: enabledSources(), preferredID: preferredID)
    }

    @discardableResult
    static func selectDefault(preferredID: String?) -> Bool {
        guard let target = DefaultInputSourcePicker.pick(from: enabledSources(), preferredID: preferredID) else {
            Log.inputSource.error("no default keyboard input source is enabled")
            return false
        }
        return select(sourceID: target.id)
    }

    @discardableResult
    static func select(sourceID: String) -> Bool {
        guard let source = selectableKeyboardSources().first(where: { $0.id == sourceID }) else {
            Log.inputSource.notice("input source \(sourceID) is no longer available")
            return false
        }
        return select(source, id: sourceID)
    }

    /// Only lifecycle operations use a fresh process. Normal switching stays native.
    /// Blocks up to the worker timeout: call it off the main thread where possible.
    nonisolated static func selectFresh(sourceID: String, workerExecutable: URL? = Bundle.main.executableURL) -> Bool {
        guard let workerExecutable else { return false }
        let result = ProcessRunner.run(executable: workerExecutable, arguments: [WorkerCommand.selectFlag, sourceID])
        Log.inputSource.notice("fresh source selection target=\(sourceID) exit=\(result?.status.description ?? "unavailable")")
        return result?.status == 0
    }

    /// TIS state as a new process sees it: this process's TIS cache can be stale
    /// right after the input method is registered or removed. Blocks up to the worker
    /// timeout: call it off the main thread (`ProcessRunner.inBackground`).
    nonisolated static func freshSnapshot(workerExecutable: URL? = Bundle.main.executableURL) -> InputSourceDiagnosticSnapshot? {
        guard let workerExecutable, WorkerCommand.runsWorkers(workerExecutable) else { return nil }
        guard let result = ProcessRunner.run(executable: workerExecutable, arguments: [WorkerCommand.statusFlag]) else { return nil }
        do {
            guard result.status == 0 else {
                Log.inputSource.error("input source diagnostic worker failed: exit=\(result.status)")
                return nil
            }
            return try JSONDecoder().decode(InputSourceDiagnosticSnapshot.self, from: result.output)
        } catch {
            Log.inputSource.error("input source diagnostic worker failed: \(error)")
            return nil
        }
    }

    static func diagnosticSnapshot() -> InputSourceDiagnosticSnapshot {
        let states = TISInputSource.keyHueSources(includeAllInstalled: true).map { source in
            InputMethodSourceState(id: source.id ?? "", enabled: source.isEnabled, selectable: source.isSelectCapable,
                                   enableCapable: source.isEnableCapable)
        }
        InputMethodSourcePreferences.shared.invalidate()
        return InputSourceDiagnosticSnapshot(enabledIDs: nativeEnabledInputMethodIDs(), currentID: current()?.id,
            sources: states, configuredIDs: InputMethodSourcePreferences.shared.enabledIDs)
    }

    static func selectNative(sourceID: String) -> Bool {
        guard let source = TISInputSource.list([kTISPropertyInputSourceID: sourceID], includeAllInstalled: false).first else { return false }
        return select(source, id: sourceID)
    }

    static func nativeEnabledInputMethodIDs() -> [String] {
        TISInputSource.keyHueSources(includeAllInstalled: false).filter(\.isSelectCapable).compactMap(\.id)
    }

    private static func select(_ source: TISInputSource, id: String) -> Bool {
        let before = current()?.id ?? "none"
        let status = TISSelectInputSource(source)
        if status != noErr {
            Log.inputSource.error("TISSelectInputSource(\(id)) failed: \(status)")
        }
        Log.inputSource.notice("source selection target=\(id) status=\(status) before=\(before) observed=\(current()?.id ?? "none")")
        return status == noErr
    }
}
