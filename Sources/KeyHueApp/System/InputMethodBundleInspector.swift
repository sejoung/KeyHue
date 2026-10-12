import Foundation
import KeyHueCore

/// Reads the packaged and the installed input method bundles: whether each is
/// KeyHue's and whether the installed one is out of date. It never changes them.
@MainActor
final class InputMethodBundleInspector {
    private static let executablePath = "Contents/MacOS/" + InputMethodIntegration.executableName
    private let payload: URL
    private let destination: URL
    private let files = FileManager.default
    /// Its fields are read only through the synthesized ==.
    private struct FileState: Equatable {
        // periphery:ignore
        var modified: Date?
        // periphery:ignore
        var size: Int?
        // periphery:ignore
        var isLink: Bool?
    }
    private var cachedFileState: [FileState] = []
    private var cached: InputMethodInstallationStatus?

    init(payload: URL, destination: URL) {
        self.payload = payload
        self.destination = destination
    }

    /// `hasRegisteredSources` is not a file's: the caller fills it in.
    func installation() -> InputMethodInstallationStatus {
        // Menus refresh on every source change. Only read binaries if files changed.
        let watched = ["", "Contents/Info.plist", Self.executablePath, "Contents/_CodeSignature/CodeResources"]
        let fileState = [payload, destination].flatMap { bundle in
            watched.map { path in
                let values = try? bundle.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
                return FileState(modified: values?.contentModificationDate, size: values?.fileSize, isLink: values?.isSymbolicLink)
            }
        }
        if fileState == cachedFileState, let cached { return cached }
        let packaged = isOwned(payload)
        let installed = isOwned(destination)
        let versionKeys = ["CFBundleShortVersionString", "CFBundleVersion"]
        let versionsMatch = versionKeys.allSatisfy { info(payload)?[$0] as? String == info(destination)?[$0] as? String }
        // Same-version development rebuilds must also offer an update.
        let contentMatches = [Self.executablePath, "Contents/_CodeSignature/CodeResources"].allSatisfy {
            (try? Data(contentsOf: payload.appendingPathComponent($0))) == (try? Data(contentsOf: destination.appendingPathComponent($0)))
        }
        let result = InputMethodInstallationStatus(hasPayload: packaged, isInstalled: installed,
                                                   needsUpdate: packaged && installed && !(versionsMatch && contentMatches))
        cachedFileState = fileState
        cached = result
        return result
    }

    /// After an operation: read the bundles again.
    func invalidate() { cached = nil }

    func exists(_ url: URL) -> Bool {
        files.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    func validate(_ url: URL) throws {
        guard isOwned(url) else { throw InputMethodManagementError.invalidBundle }
    }

    /// Only this exact service: never another app's bundle or a symbolic link.
    private func isOwned(_ url: URL) -> Bool {
        guard files.isExecutableFile(atPath: url.appendingPathComponent(Self.executablePath).path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let metadata = info(url) else { return false }
        return metadata["CFBundleIdentifier"] as? String == InputMethodIntegration.bundleID
            && metadata["CFBundleExecutable"] as? String == InputMethodIntegration.executableName
            && metadata["LSBackgroundOnly"] as? Bool == true
            && metadata["InputMethodServerControllerClass"] as? String == InputMethodIntegration.controllerClassName
            && metadata["InputMethodConnectionName"] as? String == InputMethodIntegration.connectionName
    }

    private func info(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
