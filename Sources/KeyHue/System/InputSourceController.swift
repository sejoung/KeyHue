import Carbon
import KeyHueCore
import os

/// Carbon TIS(Text Input Source) API 래퍼. 조회와 전환을 담당한다.
@MainActor
enum InputSourceController {
    private static let log = Logger(subsystem: "KeyHue", category: "InputSource")

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
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else {
            return []
        }
        return (list as NSArray).compactMap { $0 as! TISInputSource? }
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
        guard let target = DefaultInputSourcePicker.pick(from: infos, preferredID: preferredID),
              let index = infos.firstIndex(of: target) else {
            log.error("No default keyboard input source is enabled")
            return false
        }
        return select(sources[index], id: target.id)
    }

    @discardableResult
    static func select(sourceID: String) -> Bool {
        guard let source = selectableKeyboardSources().first(where: { info(for: $0).id == sourceID }) else {
            log.info("Input source \(sourceID, privacy: .public) is no longer available")
            return false
        }
        return select(source, id: sourceID)
    }

    private static func select(_ source: TISInputSource, id: String) -> Bool {
        let status = TISSelectInputSource(source)
        if status != noErr {
            log.error("TISSelectInputSource(\(id, privacy: .public)) failed: \(status)")
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
