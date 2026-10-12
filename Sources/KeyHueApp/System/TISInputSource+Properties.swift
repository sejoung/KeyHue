import Carbon
import KeyHueCore

/// Typed reads of TIS input source properties, shared by every TIS caller.
extension TISInputSource {
    func property<T>(_ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    private func flag(_ key: CFString) -> Bool {
        (property(key) as NSNumber?)?.boolValue == true
    }

    var id: String? { property(kTISPropertyInputSourceID) }
    var bundleID: String? { property(kTISPropertyBundleID) }
    var isEnabled: Bool { flag(kTISPropertyInputSourceIsEnabled) }
    var isSelectCapable: Bool { flag(kTISPropertyInputSourceIsSelectCapable) }
    var isEnableCapable: Bool { flag(kTISPropertyInputSourceIsEnableCapable) }
    var isASCIICapable: Bool { flag(kTISPropertyInputSourceIsASCIICapable) }

    var info: InputSourceInfo {
        InputSourceInfo(
            id: id ?? "",
            localizedName: property(kTISPropertyLocalizedName) ?? "",
            languages: property(kTISPropertyInputSourceLanguages) ?? [],
            isASCIICapable: isASCIICapable
        )
    }

    /// Input sources matching `filter`. `includeAllInstalled` also lists disabled ones.
    static func list(_ filter: [CFString: Any], includeAllInstalled: Bool) -> [TISInputSource] {
        let dictionary = Dictionary(uniqueKeysWithValues: filter.map { ($0.key as String, $0.value) }) as CFDictionary
        return TISCreateInputSourceList(dictionary, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    /// The KeyHue input method's parent entry and modes.
    static func keyHueSources(includeAllInstalled: Bool) -> [TISInputSource] {
        list([kTISPropertyBundleID: InputMethodIntegration.bundleID], includeAllInstalled: includeAllInstalled)
    }

    static var current: TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }
}
